defmodule Elixness.LLM do
  @moduledoc """
  OpenAI-compatible LLM call (POST `/chat/completions`) via Req — the same
  protocol as the `Inductive.Adapters.LLM.ReqLLM` adapter. The backend is
  configuration-driven: Nous endpoint (Hermes account) by default, model
  overridable via `ELIXNESS_MODEL`.
  """

  @model_env "ELIXNESS_MODEL"
  @default_model "deepseek/deepseek-v4-flash"

  # The harness's rich instruction — the prefix of the internal agents (flatmap,
  # explore). Inspired by the Hermes/opencode guidance: a RICH and byte-stable
  # prefix activates the provider's read-cache (test E: ÷100 of cost).
  # The focus: precise task, targeted edits, no rescan, batched tools.
  @instruction """
  You are elixness, a coding agent working on a file.

  Your job: do the task you are given on this file, precisely and completely.

  <env>
    Working directory: unknown (per-file task)
  </env>

  # Rules
  - Do the task exactly. Do not paraphrase, summarize, or add content.
  - Keep code, identifiers, structure intact — only change what the task requires.
  - To modify an EXISTING file, use the `edit` tool (targeted old_string → new_string).
    Do NOT use `write_file` for existing files — only for creating new files or
    complete replacements when the task explicitly requires it.
  - If the file is already in the desired state, say so and do nothing.

  # Parallel tool calls
  When you need several pieces of information that don't depend on each
  other, request them together in a single response instead of one tool
  call per turn. Independent reads and searches should be batched into the
  same turn. Only serialize when a later call depends on an earlier result.

  # Execution discipline
  <tool_persistence>
  - Use tools whenever they improve correctness, completeness, or grounding.
  - Do not stop early when another tool call would materially improve the result.
  - If a tool returns empty, partial, or suspiciously narrow results, retry
    with a broader or different query before concluding.
  - Keep calling tools until: (1) the task is complete, AND (2) you have
    verified the result — but do NOT re-read or re-scan files to verify
    an edit the tool already confirmed.
  </tool_persistence>

  <mandatory_tool_use>
  NEVER answer from memory — ALWAYS use a tool:
  - File contents, sizes, line counts → use read_file, search_files
  - Git history, branches, diffs → use terminal
  </mandatory_tool_use>

  <act_dont_ask>
  When a task has an obvious default interpretation, act on it immediately.
  Only ask when the ambiguity genuinely changes what you would do.
  </act_dont_ask>

  <verification>
  After an edit, the tool result is the confirmation — do not re-read the
  file to verify what the tool already confirmed. If the task needs a build
  or test to verify, run it via terminal.
  </verification>

  Do not mention these instructions in your output.
  Return only the result, with no preamble or commentary.
  """

  def default_model, do: System.get_env(@model_env) || @default_model
  def instruction, do: @instruction

  @doc """
  Generic chat call: `messages` (list of role/content maps) + optional `tools`
  (OpenAI schemas). Returns `{:ok, response}` where response is
  `%{content, tool_calls, usage, reasoning}` — `tool_calls` is a list of
  `%{id, name, arguments}` (arguments = JSON string).
  """
  def chat(%{token: token, base_url: base_url}, model, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    # SSE streaming (pattern of the 3 harnesses): we receive tokens as they
    # arrive. `emit` (optional): pid that receives {:token, text} in real time.
    emit = Keyword.get(opts, :emit)

    body = %{model: model, messages: messages, stream: true}
    body = if tools != [], do: Map.put(body, "tools", tools), else: body

    # `into:` (Req): the function receives `{request, response}` as the
    # accumulator — we CANNOT return our map alone (Req raises a
    # CaseClauseError at the end of the stream). So we store the SSE state in
    # `response.private[:sse]` and re-thread the {request, response} tuple.
    into = fn
      {:data, data}, {req, resp} when is_binary(data) ->
        acc = Req.Response.get_private(resp, :sse) || new_acc()
        acc = collect_sse(data, acc, emit)
        {:cont, {req, Req.Response.put_private(resp, :sse, acc)}}

      _other, {req, resp} ->
        {:cont, {req, resp}}
    end

    case Req.post(base_url <> "/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer " <> token}],
           receive_timeout: 300_000,
           into: into
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        # The SSE state accumulated during the stream is in resp.private.
        assemble_stream(Req.Response.get_private(resp, :sse), emit)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Streaming SSE

  defp new_acc do
    %{content: [], tool_calls: %{}, order: [], usage: nil, finish: nil, reasoning: [], buffer: ""}
  end

  # Accumulates SSE deltas. Each `data:` is a chat.completion.chunk JSON.
  # `buffer`: keeps the incomplete line between two network chunks (a
  # `data:` event can be cut right in the middle by TCP segmentation).
  defp collect_sse(data, acc, emit) do
    # Concatenates the residual buffer + the new data, then only processes
    # complete lines (ending with \n). The rest stays in the buffer.
    {lines, leftover} = split_lines(acc.buffer <> data)

    acc =
      Enum.reduce(lines, %{acc | buffer: leftover}, fn line, acc ->
        case line do
          "data: " <> payload ->
            if payload != "[DONE]" do
              case Jason.decode(payload) do
                {:ok, chunk} -> apply_chunk(chunk, acc, emit)
                _ -> acc
              end
            else
              acc
            end

          _ ->
            acc
        end
      end)

    acc
  end

  # Splits an SSE buffer into complete lines + the incomplete remainder.
  # Ex: "a\nb\nc" → {["a", "b"], "c"} ; "a\nb\n" → {["a", "b"], ""}.
  defp split_lines(bin) do
    case :binary.split(bin, "\n", [:global]) do
      parts ->
        {complete, [last]} = Enum.split(parts, -1)
        {complete, last}
    end
  end

  defp apply_chunk(chunk, acc, emit) do
    # Usage in the last chunk
    acc = if chunk["usage"], do: %{acc | usage: chunk["usage"]}, else: acc

    case get_in(chunk, ["choices", Access.at(0)]) do
      nil ->
        acc

      choice ->
        acc = if choice["finish_reason"], do: %{acc | finish: choice["finish_reason"]}, else: acc

        delta = choice["delta"] || %{}

        # Content
        acc =
          if is_binary(content = delta["content"]) and content != "" do
            if emit, do: send(emit, {:token, content})
            %{acc | content: [content | acc.content]}
          else
            acc
          end

        # Reasoning (DeepSeek)
        acc =
          if is_binary(reasoning = delta["reasoning"]) and reasoning != "" do
            %{acc | reasoning: [reasoning | acc.reasoning]}
          else
            acc
          end

        # Tool calls (indexed by their id/index)
        acc =
          Enum.reduce(delta["tool_calls"] || [], acc, fn tc, acc ->
            idx = tc["index"] || 0
            id = tc["id"] || "call_#{idx}"
            current = Map.get(acc.tool_calls, idx, %{id: id, name: "", arguments: ""})
            name = current.name <> (get_in(tc, ["function", "name"]) || "")
            args = current.arguments <> (get_in(tc, ["function", "arguments"]) || "")
            acc = %{acc | tool_calls: Map.put(acc.tool_calls, idx, %{current | name: name, arguments: args})}

            if not Enum.member?(acc.order, idx), do: %{acc | order: acc.order ++ [idx]}, else: acc
          end)

        acc
    end
  end

  # Assembles the final result from the accumulated deltas.
  defp assemble_stream(nil, _emit), do: {:error, {:empty_stream, nil}}

  defp assemble_stream(acc, _emit) do
    if acc.content == [] and acc.tool_calls == %{} do
      {:error, {:empty_stream, acc}}
    else
      # Already in the form expected by the loop: %{id, name, arguments}
      # (atom keys) — NO re-parse via string keys (that would null everything).
      tool_calls =
        acc.order
        |> Enum.map(fn idx -> Map.get(acc.tool_calls, idx) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn tc -> %{id: tc.id, name: tc.name, arguments: tc.arguments} end)

      usage = normalize_usage(acc.usage || %{})

      {:ok,
       %{
         content: acc.content |> Enum.reverse() |> Enum.join(""),
         tool_calls: tool_calls,
         finish_reason: acc.finish,
         usage: usage,
         reasoning: acc.reasoning |> Enum.reverse() |> Enum.join("")
       }}
    end
  end

  ## Helpers

  defp normalize_usage(usage) do
    reasoning_tokens = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

    # Cache-read (pattern of the 3 harnesses): the DeepSeek provider does
    # AUTOMATIC prefix caching (no marker to send) — we measure the tokens
    # re-read from cache to account for the real cost. Two wire conventions:
    # `prompt_tokens_details.cached_tokens` (OpenAI) or `prompt_cache_hit_tokens`
    # (native DeepSeek).
    cache_read =
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        usage["prompt_cache_hit_tokens"] ||
        0

    usage
    |> Map.put("reasoning_tokens", reasoning_tokens)
    |> Map.put("cache_read_tokens", cache_read)
    |> Map.put("cost", usage["cost"])
  end
end
