defmodule Elixness.Chat do
  @moduledoc """
  Le chat elixness — l'interface de conversation (la décision « elixness
  EST le chat »).

  Boucle : affiche le flamegraph de contexte → lit ton message → assemble
  le contexte (system + fichiers + conversation) → envoie au loop →
  affiche la réponse → répète. Le flamegraph montre ce qui part au LLM
  AVANT l'envoi (le malloc maîtrisé de context-engineering).
  """

  alias Elixness.{Auth, Context, Loop}

  @doc """
  Démarre le chat. `files` : fichiers à mettre en contexte (le dropdown).
  """
  def start(files \\ []) do
    for app <- [:jido, :finch, :req, :jason] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    case Auth.load() do
      {:ok, auth} ->
        IO.puts("elixness chat — tape ton message, /quit pour sortir, /files pour lister\n")
        loop(auth, files, [])

      {:error, reason} ->
        IO.puts("✗ elixness : #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp loop(auth, files, conversation) do
    system = system_prompt()

    ctx = Context.assemble(system: system, files: files, conversation: conversation, tools: [])

    IO.puts("── contexte ──")
    IO.puts(Context.flamegraph(ctx))
    IO.puts("")

    case IO.gets("> @") do
      :eof ->
        IO.puts("\nbye")

      {:error, _} ->
        IO.puts("\nbye")

      input ->
        msg = String.trim(input)

        cond do
          msg in ["/quit", "/exit", "/q"] ->
            IO.puts("bye")

          msg == "/files" ->
            Enum.each(files, &IO.puts("  + #{&1}"))
            loop(auth, files, conversation)

          msg == "" ->
            loop(auth, files, conversation)

          true ->
            conversation = conversation ++ [%{role: "user", content: msg}]

            case send_and_reply(auth, system, files, conversation) do
              {:ok, reply, conversation} ->
                IO.puts("\n#{reply}\n")
                loop(auth, files, conversation)

              {:error, reason} ->
                IO.puts("✗ #{inspect(reason)}\n")
                loop(auth, files, conversation)
            end
        end
    end
  end

  defp send_and_reply(auth, system, files, conversation) do
    # La conversation complète : system + fichiers en contexte + historique
    file_messages =
      Enum.map(files, fn file ->
        content = if is_map(file), do: Map.get(file, :content, ""), else: file
        %{role: "user", content: "FILE CONTEXT:\n" <> content}
      end)

    messages = [%{role: "system", content: system}] ++ file_messages ++ conversation

    # Le chat expose les tools au modèle (dont spawn_agent, flatmap) — il peut déléguer.
    # Chaque envoi a son trace (observabilité des tool_calls du chat).
    {:ok, trace} = Elixness.Trace.start_link()

    # Streaming : un process qui affiche les tool_calls EN DIRECT (comme
    # opencode/Hermes). Le loop envoie {:tool_start,...} / {:tool_end,...}.
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

  # Affiche les tool_calls en direct : "[tool] name args → result (durée)"
  # et les tokens LLM (streaming) : "texte" au fur et à mesure.
  # `safe_io` : les args/result viennent du LLM et peuvent contenir des
  # octets UTF-8 invalides (ex. pattern search_files avec accents) qui font
  # crasher :io.put_chars sur :standard_io — on sanitize avant d'écrire, ET
  # on rescue (le pattern Hermes) : l'affichage ne doit JAMAIS tuer le chat.
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
    # Filet de sécurité (pattern Hermes _cprint) : un octet qui échapperait
    # à la sanitisation ne doit pas tuer le streamer ni le chat.
    _ -> :ok
  end

  # Remplace les octets invalides par U+FFFD (même helper que Tools).
  defp sanitize_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      {:error, converted, _} -> converted
      converted -> converted
    end
  end

  # Le system prompt du chat : assistant de conversation (pas un traducteur
  # de docstrings). Résumé et direct, cohérent avec la page context-engineering.
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

  # Les règles de comportement (guidance) — copiées de Hermes (prompt_builder.py)
  # et adaptées à elixness. Le bloc Execution discipline s'applique à DeepSeek
  # (les évals de Hermes l'ont montré) — c'est notre modèle.
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

  # Affiche le coût en $ lisible (ex. "0.00152" ou "5.0e-5" → "0.00005").
  defp format_cost(nil), do: "?"
  defp format_cost(cost), do: :erlang.float_to_binary(cost, [:compact, decimals: 6])
end
