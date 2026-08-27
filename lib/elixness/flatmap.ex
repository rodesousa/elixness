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
  - `mode: :loop` (défaut) : chaque agent fait son loop (read → LLM → write).
  - `mode: :direct` : UN appel LLM par agent — le contenu est passé
    directement (le Discover l'a déjà lu), le modèle traduit, le harness
    écrit le résultat. ~3x moins de requêtes → plus rapide.
  - Retourne `%{ok:, errors:, usage:, count:, files:, traces:}` où `count` = nb d'agents lancés.
  """
  def run(root, task, opts \\ []) do
    # Pas de plafond par défaut : le flatmap traite TOUS les fichiers
    # découverts (l'utilisateur peut préciser limit pour borner).
    limit = Keyword.get(opts, :limit, :all)
    mode = Keyword.get(opts, :mode, :loop)
    model = Keyword.get(opts, :model) || Elixness.LLM.default_model()
    system = Keyword.get(opts, :system) || Elixness.LLM.instruction()

    {:ok, auth} = Auth.load()

    jobs = Discover.scan(root, limit: if(limit == :all, do: 10_000, else: limit))

    # spawn UN agent par fichier (le flatmap) — parallèle, éphémère.
    results =
      jobs
      |> Task.async_stream(
        fn job ->
          # Chaque agent a son propre trace (observabilité par fichier).
          {:ok, trace} = Elixness.Trace.start_link()

          r =
            case mode do
              :direct -> run_direct(auth, model, system, task, job)
              _ -> Loop.run(auth, model, system, task_for(job, task), tools: Elixness.Tools.schemas(), trace: trace)
            end

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

  @doc "Résumé texte compact du flatmap (ce que le modèle voit)."
  def summarize(%{ok: oks, errors: errs, usage: usage, count: count, files: files, traces: _traces}) do
    lines = ["FLATMAP RESULT: #{count} agents lancés (#{length(oks)} OK, #{length(errs)} erreurs)."]

    # Compact : les fichiers traités + un extrait court de chaque résultat.
    lines =
      lines ++
        (files
         |> Enum.zip(oks)
         |> Enum.map(fn {file, content} ->
           "  ✓ #{Path.basename(file)}: #{String.slice(content, 0, 100)}"
         end))

    lines =
      lines ++
        Enum.map(errs, fn err ->
          "  ✗ #{inspect(err)}"
        end)

    # Le git diff mécanique (pattern opencode) : les fichiers modifiés.
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
    "#{task}\n\nFile: #{job.file}\nContent:\n#{String.slice(job.text, 0, 4000)}"
  end

  # Mode :direct — UN appel LLM par agent. Le contenu est passé directement
  # (le Discover l'a déjà lu), le modèle fait la tâche, le harness écrit le
  # résultat dans le fichier. ~3x moins de requêtes que le mode :loop.
  defp run_direct(auth, model, system, task, job) do
    prompt =
      "#{task}\n\nFile: #{job.file}\nContent:\n#{String.slice(job.text, 0, 4000)}\n\n" <>
        "Do the task on the content above. Return ONLY the result, no preamble."

    messages = [
      %{role: "system", content: system},
      %{role: "user", content: prompt}
    ]

    case Elixness.LLM.chat(auth, model, messages, tools: []) do
      {:ok, %{content: content, usage: usage}} when content != "" ->
        # Le harness patche le fichier SOURCE : remplace le contenu FR
        # (job.text) par la traduction — garde les délimiteurs du moduledoc.
        patch_source(job, content)
        {:ok, content, %{usage: usage}}

      {:ok, %{content: _content, usage: _usage}} ->
        {:error, "réponse vide pour #{job.file}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Patche le fichier source : remplace job.text (le moduledoc FR) par la
  # traduction EN — les délimiteurs (" ou """) restent en place.
  defp patch_source(job, translation) do
    with {:ok, content} <- File.read(job.file),
         true <- String.contains?(content, job.text) do
      # Précision : on remplace le contenu exact, mais job.text peut apparaître
      # aussi comme sous-chaîne d'autre chose. On remplace la 1ère occurrence
      # (le moduledoc est le 1er @moduledoc généralement) — ou mieux, on vise
      # la position de la ligne/colonne. Pour un POC, on remplace la première
      # occurrence du texte exact.
      new_content = String.replace(content, job.text, translation, global: false)
      File.write!(job.file, new_content)
    else
      _ -> :ok  # ne pas crasher si le texte n'est pas trouvé (fichier déjà changé)
    end
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
