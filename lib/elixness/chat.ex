defmodule Elixness.Chat do
  @moduledoc """
  The elixness chat — the conversation interface (the "elixness IS the
  chat" decision).

  Loop: shows the context flamegraph → reads your message → assembles
  the context (system + files + conversation) → sends it to the loop →
  shows the reply → repeats. The flamegraph shows what goes to the LLM
  BEFORE the send (the controlled malloc of context-engineering).
  """

  alias Elixness.{Auth, Context, Loop}

  @doc """
  Starts the chat. `files`: files to put in context (the dropdown).
  """
  def start(files \\ []) do
    for app <- [:jido, :finch, :req, :jason] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    case Auth.load() do
      {:ok, auth} ->
        IO.puts("elixness chat — tape ton message, /quit pour sortir, /files pour lister\n")
        loop(auth, files, [], [])

      {:error, reason} ->
        IO.puts("✗ elixness : #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp loop(auth, files, conversation, history) do
    system = system_prompt()

    ctx = Context.assemble(system: system, files: files, conversation: conversation, tools: [])

    IO.puts("── contexte ──")
    IO.puts(Context.flamegraph(ctx))
    IO.puts("")

    case Elixness.LineEditor.read("> @", history) do
      :eof ->
        IO.puts("bye")

      {:error, _} ->
        IO.puts("bye")

      input ->
        msg = String.trim(input)

        cond do
          msg in ["/quit", "/exit", "/q"] ->
            IO.puts("bye")

          msg == "/files" ->
            Enum.each(files, &IO.puts("  + #{&1}"))
            loop(auth, files, conversation, history)

          msg == "" ->
            loop(auth, files, conversation, history)

          true ->
            conversation = conversation ++ [%{role: "user", content: msg}]
            history = [msg | history]

            case send_and_reply(auth, system, files, conversation) do
              {:ok, reply, conversation} ->
                IO.puts("\n#{reply}\n")
                loop(auth, files, conversation, history)

              {:error, reason} ->
                IO.puts("✗ #{inspect(reason)}\n")
                loop(auth, files, conversation, history)
            end
        end
    end
  end

  defp send_and_reply(auth, system, files, conversation) do
    # The full conversation: system + files in context + history
    file_messages =
      Enum.map(files, fn file ->
        content = if is_map(file), do: Map.get(file, :content, ""), else: file
        %{role: "user", content: "FILE CONTEXT:\n" <> content}
      end)

    messages = [%{role: "system", content: system}] ++ file_messages ++ conversation

    # The chat exposes the tools to the model (including spawn_agent, flatmap) — it can delegate.
    # Each send has its own trace (observability of the chat's tool_calls).
    {:ok, trace} = Elixness.Trace.start_link()

    # Streaming: a process that shows the tool_calls LIVE (like
    # opencode/Hermes). The loop sends {:tool_start,...} / {:tool_end,...}.
    streamer =
      spawn_link(fn -> stream_tools() end)

    case Loop.run(auth, Elixness.LLM.default_model(), system, "",
           tools: Elixness.Tools.schemas(),
           messages: messages,
           trace: trace,
           emit: streamer) do
      {:ok, content, %{usage: usage}} ->
        conversation = conversation ++ [%{role: "assistant", content: content}]
        IO.puts("  (usage: prompt=#{usage["prompt_tokens"]} completion=#{usage["completion_tokens"]} cache_read=#{usage["cache_read_tokens"]} cost=#{format_cost(usage["cost"])})")
        IO.puts(Elixness.Trace.render_summary(trace))
        {:ok, content, conversation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Shows the tool_calls live: "[tool] name args → result (duration)"
  # and the LLM tokens (streaming): "text" as they come.
  # `safe_io`: the args/result come from the LLM and may contain invalid
  # UTF-8 bytes (e.g. a search_files pattern with accents) that crash
  # :io.put_chars on :standard_io — we sanitize before writing, AND
  # we rescue (the Hermes pattern): display must NEVER kill the chat.
  defp stream_tools do
    receive do
      {:tool_start, name, args} ->
        safe_io(:puts, "  → #{name} #{args}")
        stream_tools()

      {:tool_end, name, result, duration} ->
        safe_io(:puts, "  ✓ #{name} → #{result} (#{duration}ms)")
        stream_tools()

      {:token, text} ->
        safe_io(:write, text)
        stream_tools()

      :stop ->
        :ok

      _ ->
        stream_tools()
    end
  end

  defp safe_io(kind, text) do
    safe = sanitize_utf8(to_string(text))

    case kind do
      :write -> IO.write(safe)
      :puts -> IO.puts(safe)
    end
  rescue
    # Safety net (Hermes _cprint pattern): a byte that would escape
    # sanitization must not kill the streamer or the chat.
    _ -> :ok
  end

  # Replaces invalid bytes with U+FFFD (same helper as Tools).
  defp sanitize_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      {:error, converted, _} -> converted
      converted -> converted
    end
  end

  # The chat's system prompt: conversational assistant (not a docstring
  # translator). Concise and direct, consistent with the context-engineering page.
  defp system_prompt do
    cwd = File.cwd!()

    """
    You are elixness, a conversational coding assistant built in Elixir.

    You help the user work on their codebase: answer questions, explain code,
    draft changes, translate docstrings when asked. You are concise and direct.

    <env>
      Working directory: #{cwd}
      Is a git repo: #{git_repo?()}
      Platform: #{:os.type() |> elem(0)} #{:os.type() |> elem(1)}
      Today's date: #{Date.utc_today()}
    </env>

    The user may attach file context (files in the conversation). Use it when
    relevant. Ask for more context only when genuinely needed.
    """ <>
      guidance() <>
      """

    You have delegation tools:
    - `spawn_agent`: one subagent for ONE independent subtask (a single file,
      a single question).
    - `flatmap`: process a whole directory in parallel — the harness scans,
      spawns ONE agent per file, and collects. Use this when the user asks to
      translate/review/analyze many files. Do NOT explore or count files
      yourself first — just call `flatmap` with the task and path.
    - `catalog_select`: MECHANICALLY select which files are relevant to your
      question — the harness builds a zero-LLM catalog, sends it to ONE
      subagent call, and returns the list of relevant file paths. The big
      catalog stays OUT of your context. USE THIS FIRST to find relevant
      files, then read only those with `read_file`.
    - `catalog`: build a compact ZERO-LLM catalog of a directory (paths +
      symbols + docstrings). Use ONLY when you want to see the whole
      directory structure yourself. It puts ~50-100 tokens per file in your
      context — prefer `catalog_select` which keeps it out.
    - `explore_repo`: analyze EVERY file in a directory in depth (one LLM
      agent per file — EXPENSIVE, ~100x catalog). Use ONLY when the user
      explicitly asks to process/analyze the whole directory.

    # Exploration — règle de choix (IMPORTANT)
    To understand a repo / find relevant files: call `catalog_select` FIRST.
    It returns the list of relevant files (catalog stays out of your context).
    Then read ONLY those files with `read_file` (bounded).
    Do NOT call `explore_repo` after `catalog_select` — it spawns one LLM
    agent per file (~100x the tokens). Reserve it for when the user
    explicitly asks to analyze EVERY file (e.g. "traduis tout", "review tout").
    Each subagent works in parallel with its own fresh conversation; the
    harness aggregates their usage.

    After a `flatmap` or `explore_repo` returns: the harness already verified
    the work. The result includes the changed files (git diff) and per-agent
    traces. Do NOT re-scan, re-read, or re-search the files to verify — that
    is already done. Only re-check if the user explicitly asks for it. This
    saves a huge amount of tokens.

    Respond in French by default (the user's language), unless asked otherwise.
    """
  end

  # The behavior rules (guidance) — copied from Hermes (prompt_builder.py)
  # and adapted to elixness. The Execution discipline block applies to DeepSeek
  # (Hermes' evals showed this) — it's our model.
  defp guidance do
    """
    # Parallel tool calls
    When you need several pieces of information that don't depend on each
    other, request them together in a single response instead of one tool
    call per turn. Independent reads, searches, and read-only commands should
    be batched into the same assistant turn — the runtime executes
    independent calls concurrently, and batching avoids resending the whole
    conversation on every extra round-trip. Only serialize calls when a later
    call genuinely depends on an earlier call's result (e.g. you must read a
    file before you can patch it). When in doubt and the calls are
    independent, batch them.

    # Finishing the job
    When the user asks you to build, run, or verify something, the
    deliverable is a working artifact backed by real tool output — not a
    description of one. Do not stop after writing a stub, a plan, or a single
    command. Keep working until you have actually exercised the code or
    produced the requested result, then report what real execution returned.
    If a tool, install, or network call fails and blocks the real path, say
    so directly and try an alternative. NEVER substitute plausible-looking
    fabricated output for results you couldn't actually produce.

    # Execution discipline
    <tool_persistence>
    - Use tools whenever they improve correctness, completeness, or grounding.
    - Do not stop early when another tool call would materially improve the result.
    - If a tool returns empty, partial, or suspiciously narrow results, retry
      with a broader or different query or strategy before concluding.
    - Keep calling tools until: (1) the task is complete, AND (2) you have verified
      the result.
    </tool_persistence>

    <mandatory_tool_use>
    NEVER answer these from memory or mental computation — ALWAYS use a tool:
    - File contents, sizes, line counts → use read_file, search_files
    - Git history, branches, diffs → use terminal
    Your memory describes the USER, not the system you are running on.
    </mandatory_tool_use>

    <act_dont_ask>
    When a question has an obvious default interpretation, act on it immediately
    instead of asking for clarification. Only ask for clarification when the
    ambiguity genuinely changes what tool you would call.
    </act_dont_ask>

    <verification>
    Before finalizing your response:
    - Correctness: does the output satisfy every stated requirement?
    - Grounding: are factual claims backed by tool outputs or provided context?
    - Formatting: does the output match the requested format or schema?
    - Completion: 'done' means every named acceptance criterion is verified —
      never a plausible subset. The requested output must appear in your response.
    </verification>

    <literal_preservation>
    - Preserve identifiers, commands, and values exactly as given — never
      'repair' or normalize a token that fails a stated format.
    </literal_preservation>

    <missing_context>
    - If required context is missing, do NOT guess or hallucinate an answer.
    - Use the appropriate lookup tool when missing information is retrievable.
    - Ask a clarifying question only when the information cannot be retrieved by tools.
    </missing_context>
    """
  end

  defp git_repo? do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true) do
      {"true\n", 0} -> "yes"
      _ -> "no"
    end
  end

  # Shows the readable cost in $ (e.g. "0.00152" or "5.0e-5" → "0.00005").
  defp format_cost(nil), do: "?"
  defp format_cost(cost), do: :erlang.float_to_binary(cost, [:compact, decimals: 6])
end
