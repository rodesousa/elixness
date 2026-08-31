defmodule Elixness.Flatmap do
  @moduledoc """
  The mechanical flatmap — the Huntley loop made automatic.

  `run/4` : Discover (scans the folder, identifies the jobs) → spawn ONE
  agent per file (parallel Task.async) → collects the results → returns a
  summary (translations + aggregated usage). The model calls the `flatmap`
  tool ONCE; the harness orchestrates in its place.

  This is the answer to the failure of model-driven orchestration (the 2
  chat tests: 0 agents spawned, saturation in exploration). Here, no model
  in the middle: the Discover → pool → Reduce mechanics.
  """

  alias Elixness.{Auth, Discover, Loop}

  @doc """
  Runs the flatmap on `root`.
  - `limit` : max number of jobs (files) to process.
  - `task` : the instruction given to each agent (e.g. "translate the moduledoc").
  - `mode: :loop` (default) : each agent does its loop (read → LLM → write).
  - `mode: :direct` : ONE LLM call per agent — the content is passed
    directly (Discover already read it), the model translates, the harness
    writes the result. ~3x fewer requests → faster.
  - Returns `%{ok:, errors:, usage:, count:, files:, traces:}` where `count` = number of agents spawned.
  """
  def run(root, task, opts \\ []) do
    # No cap by default: the flatmap processes ALL discovered files
    # (the user can specify limit to bound it).
    limit = Keyword.get(opts, :limit, :all)
    mode = Keyword.get(opts, :mode, :loop)
    model = Keyword.get(opts, :model) || Elixness.LLM.default_model()
    system = Keyword.get(opts, :system) || Elixness.LLM.instruction()

    {:ok, auth} = Auth.load()

    jobs = Discover.scan(root, limit: if(limit == :all, do: 10_000, else: limit))

    # spawn ONE agent per file (the flatmap) — parallel, ephemeral.
    # BOUNDED concurrency: running everything in parallel (max(length(jobs),1))
    # saturates the Finch pool on a large folder. We process ALL files with a
    # limited number of connections (same pattern as explore_repo).
    results =
      jobs
      |> Task.async_stream(
        fn job ->
          # Each agent has its own trace (per-file observability).
          {:ok, trace} = Elixness.Trace.start_link()

          r =
            case mode do
              :direct -> run_direct(auth, model, system, task, job)
              _ -> Loop.run(auth, model, system, task_for(job, task), tools: Elixness.Tools.schemas(), trace: trace)
            end

          {r, Elixness.Trace.summary(trace)}
        end,
        max_concurrency: 20,
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

  @doc "Compact text summary of the flatmap (what the model sees)."
  def summarize(%{ok: oks, errors: errs, usage: usage, count: count, files: files, traces: _traces}) do
    lines = ["FLATMAP RESULT: #{count} agents lancés (#{length(oks)} OK, #{length(errs)} erreurs)."]

    # Compact: the processed files + a short excerpt of each result.
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

    # The mechanical git diff (opencode pattern): the modified files.
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

  # :direct mode — ONE LLM call per agent. The content is passed directly
  # (Discover already read it), the model does the task, the harness writes
  # the result to the file. ~3x fewer requests than :loop mode.
  defp run_direct(auth, model, system, task, job) do
    prompt =
      "#{task}\n\nFile: #{job.file}\n\nFull file content:\n#{String.slice(job.text, 0, 12_000)}\n\n" <>
        "Do the task on the file content above. " <>
        "Return the COMPLETE modified file content (the whole file, with the changes applied). " <>
        "Do NOT return just the changed parts — return the entire file. No preamble."

    messages = [
      %{role: "system", content: system},
      %{role: "user", content: prompt}
    ]

    case Elixness.LLM.chat(auth, model, messages, tools: []) do
      {:ok, %{content: content, usage: usage}} when content != "" ->
        # The harness writes the complete modified file (direct mode: 1 call/agent).
        File.write!(job.file, content)
        {:ok, content, %{usage: usage}}

      {:ok, %{content: _content, usage: _usage}} ->
        {:error, "réponse vide pour #{job.file}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Files modified by the flatmap (git diff --name-only) — the opencode
  # pattern: the system shows what changed, the model does not re-scan.
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
      "reasoning_tokens" => 0, "cache_read_tokens" => 0, "cost" => 0.0}
  end

  defp sum_usage(a, b) do
    %{
      "prompt_tokens" => (a["prompt_tokens"] || 0) + (b["prompt_tokens"] || 0),
      "completion_tokens" => (a["completion_tokens"] || 0) + (b["completion_tokens"] || 0),
      "total_tokens" => (a["total_tokens"] || 0) + (b["total_tokens"] || 0),
      "reasoning_tokens" => (a["reasoning_tokens"] || 0) + (b["reasoning_tokens"] || 0),
      "cache_read_tokens" => (a["cache_read_tokens"] || 0) + (b["cache_read_tokens"] || 0),
      "cost" => (a["cost"] || 0.0) + (b["cost"] || 0.0)
    }
  end
end
