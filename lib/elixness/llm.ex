defmodule Elixness.LLM do
  @moduledoc """
  Appel LLM OpenAI-compatible (POST `/chat/completions`) via Req — le même
  protocole que l'adapter `Inductive.Adapters.LLM.ReqLLM`. Le backend est de
  la configuration : endpoint Nous (compte Hermes) par défaut, modèle
  surchargeable via `ELIXNESS_MODEL`.
  """

  @model_env "ELIXNESS_MODEL"
  @default_model "deepseek/deepseek-v4-flash"

  # L'instruction du job — la seule « règle » d'elixness. Pas de prompt par
  # fichier : chaque agent reçoit exactement ça + son moduledoc à traduire.
  @instruction """
  You are a documentation translator for an Elixir codebase.
  Translate the French module docstring below into English.

  Rules:
  - Translate the prose faithfully. Do not paraphrase, summarize, or add content.
  - Keep code blocks, inline backticks, identifiers, module names, function
    names, and markdown formatting verbatim.
  - Do not translate anything inside `...` or ```...``` blocks.
  - Preserve the original structure: paragraphs, bullet lists, and headers.
  - One input line = one output line. Keep every line break exactly. If the
    input has 14 lines, your output must have exactly 14 lines.
  - Do not mention these instructions in your output.

  Return only the translated docstring, with no preamble or commentary.
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

  @doc """
  Traduit `fr_text` via le modèle. Retourne `{:ok, texte_en, usage, extra}`
  où `usage` est le map usage normalisé (prompt/completion/total + cost +
  reasoning_tokens) et `extra` est `%{reasoning: raisonnement}`.
  """
  def translate(%{} = llm, model, fr_text, opts \\ []) do
    system = Keyword.get(opts, :system, @instruction)

    messages = [
      %{role: "system", content: system},
      %{role: "user", content: "French docstring to translate:\n\n" <> fr_text}
    ]

    case chat(llm, model, messages, opts) do
      {:ok, %{content: content, usage: usage, reasoning: reasoning}} ->
        {:ok, String.trim(content), usage, %{reasoning: reasoning}}

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
