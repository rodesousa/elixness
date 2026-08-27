defmodule Elixness.Actions.Translate do
  @moduledoc """
  L'action du job : un agent = un moduledoc.

  Deux modes :
  - défaut (tests A/B/E) : un appel LLM direct (prompt → traduction).
  - `loop: true` (test G) : l'agent loop complet — le modèle décide
    d'appeler des tools (read_file, write_file…) et le loop exécute et
    rejoue jusqu'à la réponse finale.

  L'échec LLM n'abat pas l'agent : il est capturé dans `state.result`
  (`ok: false`), pour que la collecte garde une ligne par fichier et que
  l'isolation des échecs du flatmap soit visible.
  """

  use Jido.Action,
    name: "translate",
    description: "Translate a French module docstring to English",
    schema: [
      file: [type: :string, required: true],
      text: [type: :string, required: true],
      line: [type: :integer, default: nil],
      delimiter: [type: :string, default: nil],
      multiturn: [type: :boolean, default: false],
      loop: [type: :boolean, default: false],
      out_dir: [type: :string, default: nil],
      inbox: [type: :any, default: nil]
    ]

  @impl true
  def run(%{file: file, text: fr_text} = params, %{state: state}) do
    started = System.monotonic_time(:millisecond)
    model = state.model || Elixness.LLM.default_model()
    system = state.system || Elixness.LLM.instruction()

    result =
      if params[:loop] do
        run_loop(file, params, state, system, model)
      else
        run_single(fr_text, params, state, system, model)
      end

    {:ok, %{result: Map.put(result, :latency_ms, System.monotonic_time(:millisecond) - started)}}
  end

  ## Mode loop (test G) — le moteur

  defp run_loop(file, params, state, system, model) do
    out_dir = params[:out_dir] || "/tmp/elixness-loop"
    File.mkdir_p!(out_dir)
    base = Path.basename(file)
    out_path = Path.join(out_dir, base <> ".en.txt")

    task =
      "Translate the @moduledoc (the French module docstring) of the file " <>
        "#{file} to English.\n\n" <>
        "Use the tools available: read_file to read the file, then write_file " <>
        "to write ONLY the translated English docstring content to #{out_path}.\n" <>
        "Keep code blocks, backticks, identifiers and structure intact.\n" <>
        "When done, reply with a short confirmation."

    case Elixness.Loop.run(state.llm, model, system, task, tools: Elixness.Tools.schemas(), inbox: params[:inbox]) do
      {:ok, content, %{usage: usage, turns: turns}} ->
        %{
          file: file,
          line: Map.get(params, :line),
          delimiter: Map.get(params, :delimiter),
          ok: true,
          en: content,
          usage: usage,
          reasoning: nil,
          turns: turns,
          out_file: out_path,
          error: nil
        }

      {:error, reason} ->
        %{
          file: file,
          line: Map.get(params, :line),
          delimiter: Map.get(params, :delimiter),
          ok: false,
          en: nil,
          usage: nil,
          reasoning: nil,
          turns: nil,
          out_file: nil,
          error: inspect(reason)
        }
    end
  end

  ## Mode simple (1 appel)

  defp run_single(fr_text, params, state, system, model) do
    user_msg =
      if params[:multiturn] do
        "Here is a complete Elixir source file. Translate ONLY the French " <>
          "@moduledoc (the module docstring) to English. Keep the rest of the " <>
          "file unchanged. Return only the translated docstring content:\n\n" <>
          fr_text
      else
        "French docstring to translate:\n\n" <> fr_text
      end

    case Elixness.LLM.translate(state.llm, model, user_msg, system: system) do
      {:ok, en, usage, extra} ->
        %{
          file: params.file,
          line: Map.get(params, :line),
          delimiter: Map.get(params, :delimiter),
          ok: true,
          en: en,
          usage: usage,
          reasoning: Map.get(extra, :reasoning),
          turns: 1,
          out_file: nil,
          error: nil
        }

      {:error, reason} ->
        %{
          file: params.file,
          line: Map.get(params, :line),
          delimiter: Map.get(params, :delimiter),
          ok: false,
          en: nil,
          usage: nil,
          reasoning: nil,
          turns: nil,
          out_file: nil,
          error: inspect(reason)
        }
    end
  end
end
