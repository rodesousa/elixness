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

    body = %{model: model, messages: messages}
    body = if tools != [], do: Map.put(body, "tools", tools), else: body

    case Req.post(base_url <> "/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer " <> token}],
           receive_timeout: 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: resp}} ->
        case get_in(resp, ["choices", Access.at(0)]) do
          nil ->
            {:error, {:empty_response, resp}}

          %{"message" => msg} ->
            usage = normalize_usage(resp["usage"] || %{})
            reasoning = msg["reasoning"] || ""

            {:ok,
             %{
               content: msg["content"] || "",
               tool_calls: parse_tool_calls(msg["tool_calls"]),
               finish_reason: get_in(resp, ["choices", Access.at(0), "finish_reason"]),
               usage: usage,
               reasoning: reasoning
             }}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
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
