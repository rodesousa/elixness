defmodule Elixness.LLM do
  @moduledoc """
  Appel LLM OpenAI-compatible (POST `/chat/completions`) via Req — le même
  protocole que l'adapter `Inductive.Adapters.LLM.ReqLLM`. Le backend est de
  la configuration : endpoint Nous (compte Hermes) par défaut, modèle
  surchargeable via `ELIXNESS_MODEL`.
  """

  @model_env "ELIXNESS_MODEL"
  @default_model "deepseek/deepseek-v4-flash"

  # L'instruction riche du harness — le prefix des agents internes (flatmap,
  # explore). Inspiré de la guidance Hermes/opencode : un prefix RICHE et
  # byte-stable active le cache-read du fournisseur (test E : ÷100 de coût).
  # Le focus : tâche précise, edits ciblés, pas de rescan, batch des tools.
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
  Appel chat générique : `messages` (liste de maps role/content) + `tools`
  optionnels (schemas OpenAI). Retourne `{:ok, response}` où response est
  `%{content, tool_calls, usage, reasoning}` — `tool_calls` est une liste de
  `%{id, name, arguments}` (arguments = string JSON).
  """
  def chat(%{token: token, base_url: base_url}, model, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    # Streaming SSE (pattern des 3 harness) : on reçoit les tokens au fur et
    # à mesure. `emit` (optionnel) : pid qui reçoit {:token, texte} en direct.
    emit = Keyword.get(opts, :emit)

    body = %{model: model, messages: messages, stream: true}
    body = if tools != [], do: Map.put(body, "tools", tools), else: body

    case Req.post(base_url <> "/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer " <> token}],
           receive_timeout: 300_000,
           into: fn {:data, data}, acc -> collect_sse(data, acc, emit) end
         ) do
      {:ok, %Req.Response{status: 200, body: acc}} ->
        # `acc` est le résultat du `into` : les deltas accumulés.
        assemble_stream(acc, emit)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Streaming SSE

  # Accumule les deltas SSE. Chaque `data:` est un JSON chat.completion.chunk.
  defp collect_sse(data, acc, emit) do
    acc = acc || %{content: [], tool_calls: %{}, order: [], usage: nil, finish: nil, reasoning: []}

    # Ne traite que les lignes `data:` (les `data: [DONE]` sont ignorées).
    data
    |> String.split("\n")
    |> Enum.each(fn line ->
      case line do
        "data: " <> payload ->
          if payload != "[DONE]" do
            case Jason.decode(payload) do
              {:ok, chunk} -> apply_chunk(chunk, acc, emit)
              _ -> :ok
            end
          end

        _ ->
          :ok
      end
    end)

    acc
  end

  defp apply_chunk(chunk, acc, emit) do
    # Usage dans le dernier chunk
    acc = if chunk["usage"], do: %{acc | usage: chunk["usage"]}, else: acc

    case get_in(chunk, ["choices", Access.at(0)]) do
      nil ->
        acc

      choice ->
        acc = if choice["finish_reason"], do: %{acc | finish: choice["finish_reason"]}, else: acc

        delta = choice["delta"] || %{}

        # Contenu
        acc =
          if content = delta["content"] do
            if emit, do: send(emit, {:token, content})
            %{acc | content: [content | acc.content]}
          else
            acc
          end

        # Reasoning (DeepSeek)
        acc =
          if reasoning = delta["reasoning"] do
            %{acc | reasoning: [reasoning | acc.reasoning]}
          else
            acc
          end

        # Tool calls (indexés par leur id/index)
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

  # Assemble le résultat final depuis les deltas accumulés.
  defp assemble_stream(acc, _emit) do
    if acc == nil or acc.content == [] and acc.tool_calls == %{} do
      {:error, {:empty_stream, acc}}
    else
      tool_calls =
        acc.order
        |> Enum.map(fn idx -> Map.get(acc.tool_calls, idx) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn tc ->
          %{
            id: tc.id,
            name: tc.name,
            arguments: tc.arguments
          }
        end)

      usage = normalize_usage(acc.usage || %{})

      {:ok,
       %{
         content: acc.content |> Enum.reverse() |> Enum.join(""),
         tool_calls: parse_tool_calls(tool_calls),
         finish_reason: acc.finish,
         usage: usage,
         reasoning: acc.reasoning |> Enum.reverse() |> Enum.join("")
       }}
    end
  end

  ## Helpers

  defp normalize_usage(usage) do
    reasoning_tokens = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

    usage
    |> Map.put("reasoning_tokens", reasoning_tokens)
    |> Map.put("cost", usage["cost"])
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"],
        name: get_in(tc, ["function", "name"]),
        arguments: get_in(tc, ["function", "arguments"]) || "{}"
      }
    end)
  end
end
