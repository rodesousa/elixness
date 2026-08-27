defmodule Elixness.Loop do
  @moduledoc """
  Le moteur du harness — l'agent loop (test G, amélioré par les patterns
  d'opencode — test H).

  Boucle : LLM → si tool_calls, exécute chaque tool et rejoue avec les
  résultats → sinon, réponse finale. C'est le « every response must make
  progress » du system prompt Hermes, rendu mécanique : le modèle décide à
  chaque turn (appeler un outil ou répondre), le loop exécute sa décision.

  Améliorations empruntées à opencode (`session/prompt.ts`) :
  1. Sortie par `finish_reason` : on ne sort que si le finish n'est pas
     "tool_calls" ET qu'il n'y a plus de tool_calls en attente.
  2. MAX_STEPS_PROMPT : à la limite d'itérations, on injecte un message qui
     force le modèle à résumer et arrêter (pas un échec sec).
  3. Condition de sortie complète : le dernier assistant doit être rattaché
     au dernier message (évite les sorties sur messages orphelins).

  Agrège l'usage (prompt/completion/reasoning/cost) sur tous les turns.
  """

  @max_iterations 8

  @max_steps_prompt """
  CRITICAL - MAXIMUM STEPS REACHED

  The maximum number of steps allowed for this task has been reached. Tools are disabled until further notice. Respond with text only.

  STRICT REQUIREMENTS:
  1. Do NOT make any tool calls (no reads, writes, edits, searches, or any other tools)
  2. MUST provide a text response summarizing what has been accomplished so far
  3. This constraint overrides ALL other instructions

  Response must include:
  - Statement that maximum steps have been reached
  - Summary of what has been accomplished so far
  - List of any remaining tasks that were not completed
  - Recommendations for what should be done next
  """

  @doc """
  Lance le loop. Retourne `{:ok, content, %{usage: usage, turns: n}}` où
  content est la réponse finale du modèle, ou `{:error, raison}`.

  Options (keyword list) :
  - `tools` : les tool schemas exposés (défaut `Elixness.Tools.schemas()`).
  - `inbox` : pid d'un `Elixness.Inbox` — le loop draine à chaque turn
    (steering : injecter des messages en cours de travail).
  - `messages` : liste complète de messages (ex. conversation d'un chat).
    Par défaut construit `[system, user_task]`.
  - `trace` : pid d'un `Elixness.Trace` — journalise chaque tool_call
    exécuté (time, args, résultat, durée). L'observabilité du harness.
  """
  def run(llm, model, system, user_task, opts \\ []) do
    tools = Keyword.get(opts, :tools, Elixness.Tools.schemas())
    inbox = Keyword.get(opts, :inbox)
    messages = Keyword.get(opts, :messages)
    trace = Keyword.get(opts, :trace)
    # `emit` : pid qui reçoit les événements tools en DIRECT ({:tool_start, name, args}
    # avant, {:tool_end, name, result, duration_ms} après) — le streaming.
    emit = Keyword.get(opts, :emit)

    messages =
      messages ||
        [
          %{role: "system", content: system},
          %{role: "user", content: user_task}
        ]

    loop(messages, llm, model, tools, 0, zero_usage(), inbox, trace, emit)
  end

  ## Boucle

  defp loop(messages, llm, model, _tools, iter, acc, _inbox, _trace, emit) when iter >= @max_iterations do
    # MAX_STEPS_PROMPT (opencode) : au lieu d'échouer sec, on force le
    # modèle à résumer et arrêter. Tools non fournis → il ne peut que
    # répondre en texte.
    case Elixness.LLM.chat(llm, model, messages ++ [%{role: "user", content: @max_steps_prompt}], emit: emit) do
      {:ok, %{content: content, usage: usage}} ->
        {:ok, content, %{usage: sum_usage(acc, usage), turns: iter + 1}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp loop(messages, llm, model, tools, iter, acc, inbox, trace, emit) do
    # Drain l'inbox : les messages en attente sont ajoutés à la conversation.
    messages = drain_inbox(messages, inbox)

    case Elixness.LLM.chat(llm, model, messages, tools: tools, emit: emit) do
      {:ok, %{content: content, tool_calls: calls, finish_reason: finish} = resp} ->
        # opencode : ne sort que si finish ≠ "tool_calls" ET pas de calls en attente
        if calls == [] and finish != "tool_calls" do
          {:ok, content, %{usage: sum_usage(acc, resp.usage), turns: iter + 1}}
        else
          # L'état du parent (llm/model/system) — nécessaire pour le tool
          # spawn_agent qui lance un child avec sa propre conversation.
          tool_state = %{llm: llm, model: model, system: get_system(messages)}

          # Le executionMode de deepseek : les tool_calls :parallel partent
          # ensemble (Task.async_stream), les :exclusive forment une barrière
          # et attendent que le groupe parallèle se vide (write, side-effects).
          {results, child_usage} = execute_calls(calls, tool_state, trace, emit)

          assistant_msg = %{
            role: "assistant",
            content: content,
            tool_calls:
              Enum.map(calls, fn c ->
                %{
                  "id" => c.id,
                  "type" => "function",
                  "function" => %{"name" => c.name, "arguments" => c.arguments}
                }
              end)
          }

          loop(
            messages ++ [assistant_msg] ++ results,
            llm,
            model,
            tools,
            iter + 1,
            sum_usage(sum_usage(acc, resp.usage), child_usage),
            inbox,
            trace,
            emit
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Exécute les tool_calls en respectant le executionMode (deepseek).
  # Groupe les :parallel ensemble (concurrence), les :exclusive en barrière.
  # Les résultats sont réordonnés selon l'ordre ORIGINAL des calls (l'API
  # OpenAI exige tool results dans le même ordre que les tool_calls).
  defp execute_calls(calls, tool_state, trace, emit) do
    {parallel, exclusive} =
      Enum.split_with(calls, fn c -> Elixness.Tools.execution_mode(c.name) == :parallel end)

    {p_results, p_usage} = run_parallel(parallel, tool_state, 10, trace, emit)
    {e_results, e_usage} = run_parallel(exclusive, tool_state, 1, trace, emit)

    # Réordonne par id de call original pour respecter l'ordre du modèle.
    by_id = Map.new(p_results ++ e_results, fn %{tool_call_id: id} = r -> {id, r} end)
    results = Enum.map(calls, fn c -> Map.fetch!(by_id, c.id) end)

    {results, sum_usage(p_usage, e_usage)}
  end

  # Lance un groupe de calls en parallèle (max_concurrency borné).
  defp run_parallel([], _tool_state, _max, _trace, _emit), do: {[], zero_usage()}

  defp run_parallel(calls, tool_state, max, trace, emit) do
    {results, usage} =
      calls
      |> Task.async_stream(
        fn call ->
          # Streaming : émet le début du tool en DIRECT (si un pid emit est fourni).
          if emit do
            send(emit, {:tool_start, call.name, truncate(call.arguments, 120)})
          end

          # Traçage : on mesure la durée et on journalise (args tronqués).
          started = System.monotonic_time(:millisecond)
          content = Elixness.Tools.execute(call, tool_state)
          duration = System.monotonic_time(:millisecond) - started

          if emit do
            send(emit, {:tool_end, call.name, truncate(inspect(content), 120), duration})
          end

          if trace do
            Elixness.Trace.log(trace, %{
              time: System.system_time(:millisecond),
              agent: self() |> inspect(),
              name: call.name,
              args: truncate(call.arguments, 200),
              result: truncate(inspect(content), 200),
              duration_ms: duration
            })
          end

          content
        end,
        max_concurrency: max,
        # PAS de timeout — les 3 harness attendent indéfiniment que les
        # sous-agents finissent (opencode raceFirst, deepseek 0 timeout).
        timeout: :infinity,
        # on_stream_timeout: :kill_task — un enfant qui dépasse (si on
        # remet un timeout un jour) est tué sans tuer le parent.
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(calls)
      |> Enum.map_reduce(zero_usage(), fn
        # Cas normal : le tool a retourné un résultat.
        {{:ok, content}, call}, acc ->
          # Le spawn retourne {:result, contenu, usage_child} — on agrège
          # l'usage du child au parent (la conso de TOUS les agents).
          case content do
            {:result, text, usage} ->
              {%{role: "tool", tool_call_id: call.id, content: text}, sum_usage(acc, usage)}

            _ ->
              {%{role: "tool", tool_call_id: call.id, content: content}, acc}
          end

        # Un enfant a crashé (exception) — on ne tue PAS le parent, on
        # renvoie l'erreur au modèle dans le résultat du tool.
        {{:exit, reason}, call}, acc ->
          {%{role: "tool", tool_call_id: call.id, content: "TOOL ERROR: #{inspect(reason)}"}, acc}

        # Un enfant a timeouté (si un timeout est configuré un jour).
        {{:error, reason}, call}, acc ->
          {%{role: "tool", tool_call_id: call.id, content: "TOOL ERROR (timeout): #{inspect(reason)}"}, acc}
      end)

    {results, usage}
  end

  ## Usage

  defp truncate(s, n) when is_binary(s) and byte_size(s) > n, do: binary_part(s, 0, n) <> "…"
  defp truncate(s, _n), do: s

  defp get_system(messages) do
    Enum.find_value(messages, "", fn
      %{role: "system", content: c} -> c
      _ -> nil
    end)
  end

  defp drain_inbox(messages, nil), do: messages

  defp drain_inbox(messages, inbox) do
    case Elixness.Inbox.drain(inbox) do
      [] -> messages
      pending -> messages ++ Enum.map(pending, fn {msg, _kind} -> %{role: "user", content: msg} end)
    end
  end

  defp zero_usage do
    %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0,
      "reasoning_tokens" => 0, "cost" => 0.0}
  end

  defp sum_usage(acc, usage) do
    %{
      "prompt_tokens" => (acc["prompt_tokens"] || 0) + (usage["prompt_tokens"] || 0),
      "completion_tokens" => (acc["completion_tokens"] || 0) + (usage["completion_tokens"] || 0),
      "total_tokens" => (acc["total_tokens"] || 0) + (usage["total_tokens"] || 0),
      "reasoning_tokens" => (acc["reasoning_tokens"] || 0) + (usage["reasoning_tokens"] || 0),
      "cost" => (acc["cost"] || 0.0) + (usage["cost"] || 0.0)
    }
  end
end
