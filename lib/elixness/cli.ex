defmodule Elixness.CLI do
  @moduledoc """
  Entry point for the `elixness` escript.

      elixness chat [--files f1,f2] [--system chemin]
      elixness help

  The chat is the harness surface: conversation + tools + delegation.
  """

  def main(args) do
    # Starts the apps that HTTP (Req/Finch), JSON, and Jido depend on.
    for app <- [:jido, :finch, :req, :jason] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    # The inbox Registry (the file→inbox directory) — the foundation of the chat.
    {:ok, _} = Elixness.InboxRegistry.start_link()

    # The directory of active children (Agent) — for steering + cancellation.
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
    elixness — the harness: a conversational agent with tools.

      elixness chat [--files f1,f2] [--system chemin]
      elixness help

    chat: interactive conversation with context flamegraph (the visible malloc),
    tools (read/write/edit/glob/search/web/terminal) + delegation (flatmap, explore_repo).
    LLM: Nous endpoint (Hermes account, ~/.hermes/auth.json), model #{Elixness.LLM.default_model()}.
    """
  end
end
