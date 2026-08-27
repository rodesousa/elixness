defmodule Elixness.Explore do
  @moduledoc """
  L'exploration mécanique d'un repo — `explore_repo`.

  Le pattern Huntley complet : **rg/glob (découverte) → flatmap (spawn UN agent
  par fichier qui analyse) → reduce (résumé agrégé)**.

  Le modèle appelle `explore_repo(path)` UNE fois au lieu de lire fichier par
  fichier (le problème observé : 21 read_file / 176k prompt pour « quels sont
  les tools d'opencode ? »). Ici le harness :
  1. liste les fichiers candidats (rg/glob, rapide, .gitignore respecté)
  2. spawn UN agent par fichier qui extrait les points clés (moduledoc,
     définitions, TODO — ce qui est pertinent pour la question)
  3. collecte et résume → le modèle reçoit un résumé structuré en 1 appel.
  """

  alias Elixness.{Auth, LLM}

  # Garde-fou budget : on ne lance JAMAIS 1 agent LLM par fichier si la liste
  # pertinente est énorme — le coût exploserait. Au-delà de ce seuil on coupe
  # (le modèle peut passer un limit explicite pour borner davantage).
  @max_analyze 200

  @doc """
  Explore `path` avec la question `question`.
  - `limit` : nombre max de fichiers à analyser (défaut `:all` = illimité).
  - Retourne `%{ok:, errors:, usage:, count:, files:, summary:}` où `summary`
    est le résumé texte concaténé (ce que le modèle voit).
  """
  def run(path, question, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)
    model = Keyword.get(opts, :model) || LLM.default_model()
    system = Keyword.get(opts, :system) || LLM.instruction()

    {:ok, auth} = Auth.load()

    files = discover_files(path, limit)

    # Garde-fou budget (leçon des 3 harness : le runtime borne, pas le modèle) :
    # on ne lance JAMAIS 1 agent LLM par fichier si la liste est énorme — le
    # coût exploserait. Au-delà du seuil, on coupe (le modèle peut passer un
    # limit explicite pour borner davantage, ou réduire le périmètre d'abord).
    files = if length(files) > @max_analyze, do: Enum.take(files, @max_analyze), else: files

    # flatmap : spawn UN agent par fichier qui analyse (mode :direct — 1 appel
    # LLM par fichier, le contenu est passé directement par le harness).
    # Concurrence BORNÉE : tout en parallèle (max(length(files),1)) sature le
    # pool Finch avec un grand repo (ex. 8780 fichiers → "excess queuing").
    # On traite TOUS les fichiers mais avec un nombre de connexions limité.
    results =
      files
      |> Task.async_stream(
        fn file ->
          analyze_file(auth, model, system, question, file)
        end,
        max_concurrency: 20,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.to_list()

    {oks, errs, usage} =
      Enum.reduce(results, {[], [], zero_usage()}, fn
        {:ok, {:ok, content, %{usage: u}}}, {o, e, acc} ->
          {[content | o], e, sum_usage(acc, u)}

        {:ok, {:error, reason}}, {o, e, acc} ->
          {o, [reason | e], acc}

        {:exit, reason}, {o, e, acc} ->
          {o, [{:crash, reason} | e], acc}
      end)

    %{
      ok: Enum.reverse(oks),
      errors: Enum.reverse(errs),
      usage: usage,
      count: length(files),
      files: files,
      summary: Enum.join(Enum.reverse(oks), "\n\n")
    }
  end

  ## Découverte (rg/glob — le harness trouve les fichiers)

  # Liste les fichiers du repo. Leçon des 3 harness (deepseek/opencode/Hermes) :
  # personne ne pré-filtre les fichiers par pertinence — c'est le modèle qui
  # réduit le périmètre avec ses tools (search_files/glob) avant de déléguer.
  # Le rôle du harness est de BORNER (garde-fou budget + concurrency), pas de
  # décider quoi analyser. `limit` borne la liste (défaut :all = tous).
  defp discover_files(path, limit) do
    take = if limit == :all, do: 10_000, else: limit

    # rg --files respecte .gitignore et saute les binaires — le backbone recommandé.
    case System.cmd("rg", ["--files", "-g", "*.{ex,exs,ts,tsx,js,py,md}", path], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.take(take)

      _ ->
        # fallback glob si rg absent
        Path.join(path, "**/*.{ex,exs,ts,tsx,js,py,md}")
        |> Path.wildcard()
        |> Enum.take(take)
    end
  end

  ## flatmap : UN appel LLM par fichier (le contenu est déjà lu par le harness)

  defp analyze_file(auth, model, system, question, file) do
    content =
      case File.read(file) do
        {:ok, c} -> String.slice(c, 0, 4000)
        {:error, _} -> "(illisible)"
      end

    prompt =
      "Question: #{question}\n\nFile: #{file}\n\nContent:\n#{content}\n\n" <>
        "Analyze this file and extract ONLY the key points relevant to the question " <>
        "(definitions, docstrings, important symbols). Be concise — max 5 lines."

    messages = [
      %{role: "system", content: system},
      %{role: "user", content: prompt}
    ]

    case LLM.chat(auth, model, messages, tools: []) do
      {:ok, %{content: content, usage: usage}} when content != "" ->
        {:ok, "#{file}:\n#{String.trim(content)}", %{usage: usage}}

      {:ok, %{content: _content, usage: _usage}} ->
        {:error, "réponse vide pour #{file}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp zero_usage do
    %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0,
      "reasoning_tokens" => 0, "cost" => 0.0}
  end

  defp sum_usage(a, b) do
    %{
      "prompt_tokens" => a["prompt_tokens"] + b["prompt_tokens"],
      "completion_tokens" => a["completion_tokens"] + b["completion_tokens"],
      "total_tokens" => a["total_tokens"] + b["total_tokens"],
      "reasoning_tokens" => a["reasoning_tokens"] + b["reasoning_tokens"],
      "cost" => (a["cost"] || 0) + (b["cost"] || 0)
    }
  end
end
