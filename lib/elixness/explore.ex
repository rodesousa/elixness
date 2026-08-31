defmodule Elixness.Explore do
  @moduledoc """
  Mechanical exploration of a repo — `explore_repo`.

  The full Huntley pattern: **rg/glob (discovery) → flatmap (spawn ONE agent
  per file that analyzes it) → reduce (aggregated summary)**.

  The model calls `explore_repo(path)` ONCE instead of reading file by file
  (the observed problem: 21 read_file / 176k prompt for "what are the tools
  of opencode?"). Here the harness:
  1. lists the candidate files (rg/glob, fast, .gitignore respected)
  2. spawns ONE agent per file that extracts the key points (moduledoc,
     definitions, TODO — whatever is relevant to the question)
  3. collects and summarizes → the model receives a structured summary in 1 call.
  """

  alias Elixness.{Auth, LLM}

  # Budget guard: we NEVER launch 1 LLM agent per file if the relevant list
  # is huge — the token cost would explode. Beyond this threshold we cut
  # (the model can pass an explicit limit to bound further,
  # or reduce the scope first).
  @max_analyze 200

  @doc """
  Explore `path` with the question `question`.
  - `limit`: max number of files to analyze (default `:all` = unlimited).
  - Returns `%{ok:, errors:, usage:, count:, files:, summary:}` where `summary`
    is the concatenated text summary (what the model sees).
  """
  def run(path, question, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)
    model = Keyword.get(opts, :model) || LLM.default_model()
    system = Keyword.get(opts, :system) || LLM.instruction()

    {:ok, auth} = Auth.load()

    files = discover_files(path, limit)

    # Budget guard (lesson from the 3 harnesses: the runtime bounds, not the model):
    # we NEVER launch 1 LLM agent per file if the list is huge — the
    # cost would explode. Beyond the threshold, we cut (the model can pass an
    # explicit limit to bound further, or reduce the scope first).
    files = if length(files) > @max_analyze, do: Enum.take(files, @max_analyze), else: files

    # flatmap: spawn ONE agent per file that analyzes it (mode :direct — 1 LLM
    # call per file, the content is passed directly by the harness).
    # BOUNDED concurrency: everything in parallel (max(length(files),1)) saturates
    # the Finch pool with a large repo (e.g. 8780 files → "excess queuing").
    # We process ALL files but with a limited number of connections.
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

  ## Discovery (rg/glob — the harness finds the files)

  # Lists the files in the repo. Lesson from the 3 harnesses (deepseek/opencode/Hermes):
  # nobody pre-filters the files by relevance — it's the model that
  # reduces the scope with its tools (search_files/glob) before delegating.
  # The harness's role is to BOUND (budget guard + concurrency), not to
  # decide what to analyze. `limit` bounds the list (default :all = all).
  defp discover_files(path, limit) do
    take = if limit == :all, do: 10_000, else: limit

    # rg --files respects .gitignore and skips binaries — the recommended backbone.
    case System.cmd("rg", ["--files", "-g", "*.{ex,exs,ts,tsx,js,py,md}", path], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.take(take)

      _ ->
        # glob fallback if rg is missing
        Path.join(path, "**/*.{ex,exs,ts,tsx,js,py,md}")
        |> Path.wildcard()
        |> Enum.take(take)
    end
  end

  ## flatmap: ONE LLM call per file (the content is already read by the harness)

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
      "reasoning_tokens" => 0, "cache_read_tokens" => 0, "cost" => 0.0}
  end

  defp sum_usage(a, b) do
    %{
      "prompt_tokens" => a["prompt_tokens"] + b["prompt_tokens"],
      "completion_tokens" => a["completion_tokens"] + b["completion_tokens"],
      "total_tokens" => a["total_tokens"] + b["total_tokens"],
      "reasoning_tokens" => a["reasoning_tokens"] + b["reasoning_tokens"],
      "cache_read_tokens" => (a["cache_read_tokens"] || 0) + (b["cache_read_tokens"] || 0),
      "cost" => (a["cost"] || 0) + (b["cost"] || 0)
    }
  end
end
