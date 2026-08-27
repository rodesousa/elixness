defmodule Elixness.CLI do
  @moduledoc """
  Point d'entrée de l'escript `elixness`.

      elixness chat [--files f1,f2] [--system chemin]
      elixness help

  Le chat est la surface du harness : conversation + tools + délégation.
  """

  def main(args) do
    # Démarre les apps dont dépendent l'HTTP (Req/Finch), JSON et Jido.
    for app <- [:jido, :finch, :req, :jason] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    # Le Registry des inbox (l'annuaire fichier→inbox) — la fondation du chat.
    {:ok, _} = Elixness.InboxRegistry.start_link()

    # L'annuaire des enfants actifs (Agent) — pour le steering + l'annulation.
    {:ok, _} = Elixness.ChildRegistry.start_link(name: Elixness.ChildRegistry)

    args
    |> parse_args()
    |> run()
  end

  ## Parsing

  defp parse_args(args) do
    {command, rest} =
      case args do
        [command | rest] -> {command, rest}
        [] -> {"help", []}
      end

    {command, parse_opts(rest, %{limit: 10, dry_run: false, apply: false, model: nil, concurrency: 10, multiturn: false, loop: true})}
  end

  defp parse_opts([], opts), do: opts

  defp parse_opts(["--limit", n | rest], opts) do
    parse_opts(rest, %{opts | limit: String.to_integer(n)})
  end

  defp parse_opts(["--dry-run" | rest], opts), do: parse_opts(rest, %{opts | dry_run: true})
  defp parse_opts(["--apply" | rest], opts), do: parse_opts(rest, %{opts | apply: true})
  defp parse_opts(["--multiturn" | rest], opts), do: parse_opts(rest, %{opts | multiturn: true})
  defp parse_opts(["--loop" | rest], opts), do: parse_opts(rest, %{opts | loop: true})
  defp parse_opts(["--no-loop" | rest], opts), do: parse_opts(rest, %{opts | loop: false})

  defp parse_opts(["--model", m | rest], opts) do
    parse_opts(rest, %{opts | model: m})
  end

  defp parse_opts(["--concurrency", n | rest], opts) do
    parse_opts(rest, %{opts | concurrency: String.to_integer(n)})
  end

  defp parse_opts([other | _], _opts), do: raise("option inconnue : #{other}")

  ## Dispatch

  defp run({"help", _}), do: IO.puts(usage())

  defp run({"chat", _opts}) do
    Elixness.Chat.start([])
  end

  defp run({command, _}), do: raise("commande inconnue : #{command} — voir `elixness help`")

  defp usage do
    """
    elixness — le harness : un agent de conversation avec outils.

      elixness chat [--files f1,f2] [--system chemin]
      elixness help

    chat : conversation interactive avec flamegraph de contexte (le malloc visible),
    tools (read/write/edit/glob/search/web/terminal) + délégation (flatmap, explore_repo).
    LLM : endpoint Nous (compte Hermes, ~/.hermes/auth.json), modèle #{Elixness.LLM.default_model()}.
    """
  end
end
