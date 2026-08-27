defmodule Elixness.Agents.Translator do
  @moduledoc """
  L'agent map du flatmap : reçoit un `@moduledoc` français via le signal
  `translate`, appelle le LLM, et range le résultat dans `state.result`.

  Stateless par design (tout le contexte voyage dans le signal) — c'est ce
  qui le rend utilisable dans un worker pool sans fuite d'état entre deux
  jobs. La config LLM (token, endpoint, modèle) est partagée dans
  `state.llm` / `state.model`.
  """

  use Jido.Agent,
    name: "translator",
    description: "Translates a French module docstring to English",
    schema: [
      llm: [type: :map, default: %{}],
      model: [type: :string, default: nil],
      result: [type: :map, default: nil]
    ],
    signal_routes: [{"translate", Elixness.Actions.Translate}]
end
