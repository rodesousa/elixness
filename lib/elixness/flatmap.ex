defmodule Elixness.Flatmap do
  @moduledoc """
  Le flatmap mécanique — le loop de Huntley rendu automatique.

  `run/4` : Discover (scanne le dossier, identifie les jobs) → spawn UN agent
  par fichier (Task.async parallèle) → collecte les résultats → retourne un
  résumé (traductions + usage agrégé). Le modèle appelle le tool `flatmap`
  UNE fois ; le harness orchestre à sa place.

  C'est la réponse à l'échec de l'orchestration par le modèle (les 2 tests
  chat : 0 agent spawné, saturation en exploration). Ici, pas de modèle au
  milieu : la mécanique Discover → pool → Reduce.
  """

  alias Elixness.{Auth, Discover, Loop}

  @doc """
  Lance le flatmap sur `root`.
  - `limit` : nombre max de jobs (fichiers) à traiter.
  - `task` : l'instruction donnée à chaque agent (ex. « traduis le moduledoc »).
  - Retourne `%{ok:, errors:, usage:, count:, files:}` où `count` = nb d'agents lancés.
  """
  def run(root, task, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    model = Keyword.get(opts, :model) || Elixness.LLM.default_model()
    system = Keyword.get(opts, :system) || Elixness.LLM.instruction()

    {:ok, auth} = Auth.load()

    jobs = Discover.scan(root, limit: limit)

    # spawn UN agent par fichier (le flatmap) — parallèle, éphémère.
    results =
      jobs
      |> Task.async_stream(
        fn job ->
          # Chaque agent a son propre trace (observabilité par fichier).
          {:ok, trace} = Elixness.Trace.start_link()
          r = Loop.run(auth, model, system, task_for(job, task), Elixness.Tools.schemas(), nil, nil, trace)
          {r, Elixness.Trace.summary(trace)}
        end,
        max_concurrency: max(length(jobs), 1),
        timeout: :infinity,
        ordered: true
      )
      |> Enum.to_list()

    {oks, errs, usage, traces} =
      Enum.reduce(results, {[], [], zero_usage(), []}, fn
        {:ok, {{:ok, content, %{usage: u}}, trace}}, {o, e, acc, t} ->
          {[content | o], e, sum_usage(acc, u), [trace | t]}

        {:ok, {{:error, reason}, trace}}, {o, e, acc, t} ->
          {o, [reason | e], acc, [trace | t]}

        {:exit, reason}, {o, e, acc, t} ->
          {o, [{:crash, reason} | e], acc, t}
      end)

    %{
      ok: Enum.reverse(oks),
      errors: Enum.reverse(errs),
      usage: usage,
      count: length(jobs),
      files: Enum.map(jobs, & &1.file),
      traces: Enum.reverse(traces)
    }
  end

  @doc "Résumé texte du flatmap (ce que le modèle voit)."
  def summarize(%{ok: oks, errors: errs, usage: usage, count: count, traces: traces}) do
    lines = ["FLATMAP RESULT: #{count} agents lancés (#{length(oks)} OK, #{length(errs)} erreurs)."]

    lines =
      lines ++
        Enum.map(oks, fn content ->
          "  ✓ #{String.slice(content, 0, 200)}"
        end)

    lines =
      lines ++
        Enum.map(errs, fn err ->
          "  ✗ #{inspect(err)}"
        end)

    lines =
      lines ++
        Enum.map(traces, fn trace ->
          "  [trace] " <> Elixness.Trace.render_summary(trace)
        end)

    # Le git diff mécanique (pattern opencode) : le harness montre ce qui a
    # changé — le modèle n'a PAS à re-scanner pour vérifier.
    lines =
      lines ++
        ["", "CHANGED FILES (git diff --name-only):"] ++
          git_diff_name_only() ++
          [""]

    lines =
      lines ++
        [
          "TOTAL usage: prompt=#{usage["prompt_tokens"]} completion=#{usage["completion_tokens"]} " <>
            "cost=#{usage["cost"]}"
        ]

    Enum.join(lines, "\n")
  end

  defp task_for(job, task) do
    "#{task}\n\nFile: #{job.file}\nFrench content:\n#{job.text}"
  end

  # Les fichiers modifiés par le flatmap (git diff --name-only) — le pattern
  # opencode : le système montre ce qui a changé, le modèle ne re-scane pas.
  defp git_diff_name_only do
    case System.cmd("git", ["diff", "--name-only"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn f -> "  + #{f}" end)

      _ ->
        ["  (pas de repo git — diff indisponible)"]
    end
  end

  defp zero_usage do
    %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0,
      "reasoning_tokens" => 0, "cost" => 0.0}
  end

  defp sum_usage(a, b) do
    %{
      "prompt_tokens" => (a["prompt_tokens"] || 0) + (b["prompt_tokens"] || 0),
      "completion_tokens" => (a["completion_tokens"] || 0) + (b["completion_tokens"] || 0),
      "total_tokens" => (a["total_tokens"] || 0) + (b["total_tokens"] || 0),
      "reasoning_tokens" => (a["reasoning_tokens"] || 0) + (b["reasoning_tokens"] || 0),
      "cost" => (a["cost"] || 0.0) + (b["cost"] || 0.0)
    }
  end
end
