defmodule Elixness.CLI do
  @moduledoc """
  Point d'entrée de l'escript `elixness`.

      elixness translate [--limit N] [--dry-run] [--apply] [--model M]
      elixness help

  Lancé depuis la racine du projet cible. `--dry-run` s'arrête après le
  discover (estimation des tokens, aucun appel LLM). Sans `--apply`, les
  traductions sont affichées mais rien n'est écrit dans les fichiers.
  """

  alias Elixness.{Auth, Discover, Reduce, Apply}
  alias Elixness.Agents.Translator

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

  defp run({"translate", opts}) do
    case translate(opts) do
      :ok -> :ok
      {:error, reason} ->
        IO.puts("\n✗ elixness : #{inspect(reason)}")
        System.halt(1)
    end
  rescue
    e -> IO.puts("\n✗ elixness : #{Exception.message(e)}")
         System.halt(1)
  end

  defp run({command, _}), do: raise("commande inconnue : #{command} — voir `elixness help`")

  defp usage do
    """
    elixness — le harness : traduit les @moduledoc français + chat de conversation.

      elixness translate [--limit N] [--concurrency N] [--dry-run] [--apply] [--model M] [--no-loop]
      elixness chat [--files f1,f2] [--system chemin]
      elixness help

    translate : batch de traduction via N agents Jido (loop par défaut).
    chat : conversation interactive avec flamegraph de contexte (le malloc visible).
    LLM : endpoint Nous (compte Hermes, ~/.hermes/auth.json), modèle #{Elixness.LLM.default_model()}.
    """
  end

  ## Le job

  defp translate(opts) do
    root = File.cwd!()

    with {:ok, auth} <- Auth.load() do
      jobs = Discover.scan(root, limit: opts.limit)

      if jobs == [] do
        IO.puts("Aucun @moduledoc français trouvé dans #{root}/lib")
        {:ok, _} = {:ok, :none}
        :ok
      else
        IO.puts("elixness translate — #{length(jobs)} moduledoc(s) français trouvé(s) dans #{root}\n")
        IO.puts("  pré-flight (estimation, avant tout appel LLM) :")
        Enum.each(jobs, fn j ->
          IO.puts("    ~#{String.pad_leading(Integer.to_string(j.est_tokens), 5)} tok  #{j.file}:#{j.line}")
        end)

        total_est = Enum.sum(Enum.map(jobs, & &1.est_tokens))
        IO.puts("\n  TOTAL estimé : ~#{total_est} tokens (instruction + texte, #{length(jobs)} agents)\n")

        if opts.dry_run do
          IO.puts("  (--dry-run : aucun appel LLM, aucune écriture)")
          :ok
        else
          run_map_reduce(jobs, opts, auth)
        end
      end
    end
  end

  defp run_map_reduce(jobs, opts, auth) do
    concurrency = min(opts[:concurrency], length(jobs))
    pool_size = max(concurrency, 1)
    model = opts[:model] || Elixness.LLM.default_model()
    system = system_prompt()

    {:ok, _pid} =
      Elixness.Jido.start_link(
        name: Elixness.Jido,
        agent_pools: [
          {:translator, Translator,
           size: pool_size,
           max_overflow: 0,
           worker_opts: [initial_state: %{llm: auth, model: model, system: system}]}
        ]
      )

    IO.puts(
      "  map : pool de #{pool_size} agent(s) Jido, #{length(jobs)} job(s), " <>
        "concurrence #{concurrency}…\n"
    )

    started = System.monotonic_time(:millisecond)

    results =
      jobs
      |> Task.async_stream(
        fn job ->
          # Chaque job a son inbox, enregistrée dans le Registry (annuaire
          # fichier→inbox) : n'importe qui peut steerer pendant la traduction.
          {:ok, inbox} = Elixness.Inbox.start_link()
          Elixness.InboxRegistry.register(job.file, inbox)

          # Test F : mode multi-turn — on lit le fichier complet (comme
          # read_file) et on le passe en contexte, au lieu du moduledoc seul.
          context =
            if opts[:multiturn] do
              case File.read(job.file) do
                {:ok, content} -> content
                {:error, _} -> job.text
              end
            else
              job.text
            end

          signal =
            Jido.Signal.new!("translate",
              %{file: job.file, text: context, line: job.line, delimiter: job.delimiter,
                multiturn: opts[:multiturn], loop: opts[:loop],
                out_dir: "/tmp/elixness-loop", inbox: inbox},
              source: "/elixness/translate"
            )

          case Jido.Agent.WorkerPool.call(Elixness.Jido, :translator, signal,
                 timeout: length(jobs) * 130_000,
                 call_timeout: 120_000
               ) do
            {:ok, agent} -> agent.state.result
            {:error, reason} ->
              %{file: job.file, line: job.line, ok: false, en: nil, usage: nil,
                latency_ms: 0, error: inspect(reason)}
          end
        end,
        max_concurrency: concurrency,
        timeout: max(150_000, length(jobs) * 150_000),
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{file: "?", line: nil, ok: false, en: nil, usage: nil, latency_ms: 0, error: inspect(reason)}
      end)

    report(Reduce.run(results, started), opts)
  end

  defp report(%{ok: ok, failed: failed, totals: totals, wall_ms: wall_ms, sum_latency: sum_latency}, opts) do
    IO.puts("  reduce :\n")

    Enum.each(ok, fn r ->
      u = r.usage || %{}
      turns = if r[:turns], do: "turns=#{r.turns}", else: ""
      IO.puts(
        "    ✓ #{r.file}:#{r.line}   " <>
          "prompt=#{u["prompt_tokens"]} completion=#{u["completion_tokens"]} total=#{u["total_tokens"]}  " <>
          "reason=#{u["reasoning_tokens"]} cost=$#{format_cost(u["cost"])}  " <>
          "#{turns} (#{Float.round(r.latency_ms / 1000, 1)}s)"
      )
    end)

    Enum.each(failed, fn r ->
      IO.puts("    ✗ #{r.file}:#{r.line}   #{r.error}")
    end)

    total = totals.total
    reasoning = Enum.sum(Enum.map(ok, &(&1.usage["reasoning_tokens"] || 0)))
    cost = Enum.sum(Enum.map(ok, &(&1.usage["cost"] || 0)))
    IO.puts(
      "\n  total tokens : prompt=#{totals.prompt} completion=#{totals.completion} total=#{total}" <>
        " (reasoning=#{reasoning})  coût ≈ $#{format_cost(cost)}" <>
        "  — temps mural #{Float.round(wall_ms / 1000, 1)}s" <>
        " (somme des latences #{Float.round(sum_latency / 1000, 1)}s" <>
        " → parallélisme ~#{parallel_factor(wall_ms, sum_latency)}x)"
    )

    IO.puts("  ok: #{length(ok)} / #{length(ok) + length(failed)}")

    if opts.apply do
      files = Apply.write(ok)
      IO.puts("\n  apply : #{length(files)} fichier(s) écrit(s).\n  → review avec `git diff`, revert avec `git checkout -- <fichiers>`")
    else
      IO.puts("\n  (aucune écriture — relance avec --apply pour écrire les fichiers)")
    end

    :ok
  end

  defp parallel_factor(_wall, 0), do: 1
  defp parallel_factor(wall, sum), do: Float.round(sum / max(wall, 1), 1)

  # Test E : system prompt externe via ELIXNESS_SYSTEM_PROMPT (fichier).
  # Défaut = l'instruction du job.
  defp system_prompt do
    case System.get_env("ELIXNESS_SYSTEM_PROMPT") do
      nil -> Elixness.LLM.instruction()
      "" -> Elixness.LLM.instruction()
      path -> File.read!(path)
    end
  end

  defp format_cost(nil), do: "?"
  defp format_cost(cost), do: Float.round(cost, 5) |> Float.to_string()
end
