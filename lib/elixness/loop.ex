defmodule Elixness.Loop do
  @moduledoc """
  The harness engine — the agent loop (test G, improved by the opencode
  patterns — test H).

  Loop: LLM → if tool_calls, execute each tool and replay with the
  results → otherwise, final answer. It's the "every response must make
  progress" of the Hermes system prompt, made mechanical: the model
  decides at each turn (call a tool or answer), the loop executes its
  decision.

  Improvements borrowed from opencode (`session/prompt.ts`):
  1. Exit by `finish_reason`: we only exit if the finish is not
     "tool_calls" AND there are no more pending tool_calls.
  2. MAX_STEPS_PROMPT: at the iteration limit, we inject a message that
     forces the model to summarize and stop (not a hard failure).
  3. Complete exit condition: the last assistant must be attached
     to the last message (avoids exits on orphan messages).

  Aggregates usage (prompt/completion/reasoning/cost) across all turns.
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
  Runs the loop. Returns `{:ok, content, %{usage: usage, turns: n}}` where
  content is the model's final response, or `{:error, reason}`.

  Options (keyword list):
  - `tools`: the exposed tool schemas (default `Elixness.Tools.schemas()`).
  - `inbox`: pid of an `Elixness.Inbox` — the loop drains it at each turn
    (steering: inject messages while working).
  - `messages`: full list of messages (e.g. a chat conversation).
    By default builds `[system, user_task]`.
  - `trace`: pid of an `Elixness.Trace` — logs each executed tool_call
    (time, args, result, duration). The harness's observability.
  """
  def run(llm, model, system, user_task, opts \\ []) do
    tools = Keyword.get(opts, :tools, Elixness.Tools.schemas())
    inbox = Keyword.get(opts, :inbox)
    messages = Keyword.get(opts, :messages)
    trace = Keyword.get(opts, :trace)
    # `emit`: pid that receives tool events in REALTIME ({:tool_start, name, args}
    # before, {:tool_end, name, result, duration_ms} after) — the streaming.
    emit = Keyword.get(opts, :emit)

    messages =
      messages ||
        [
          %{role: "system", content: system},
          %{role: "user", content: user_task}
        ]

    loop(messages, llm, model, tools, 0, zero_usage(), inbox, trace, emit)
  end

  ## Loop

  defp loop(messages, llm, model, _tools, iter, acc, _inbox, _trace, emit) when iter >= @max_iterations do
    # MAX_STEPS_PROMPT (opencode): instead of failing hard, we force the
    # model to summarize and stop. Tools not provided → it can only
    # respond in text.
    case Elixness.LLM.chat(llm, model, messages ++ [%{role: "user", content: @max_steps_prompt}], emit: emit) do
      {:ok, %{content: content, usage: usage}} ->
        {:ok, content, %{usage: sum_usage(acc, usage), turns: iter + 1}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp loop(messages, llm, model, tools, iter, acc, inbox, trace, emit) do
    # Drains the inbox: pending messages are added to the conversation.
    messages = drain_inbox(messages, inbox)

    case Elixness.LLM.chat(llm, model, messages, tools: tools, emit: emit) do
      {:ok, %{content: content, tool_calls: calls, finish_reason: finish} = resp} ->
        # opencode: only exits if finish ≠ "tool_calls" AND no pending calls
        if calls == [] and finish != "tool_calls" do
          {:ok, content, %{usage: sum_usage(acc, resp.usage), turns: iter + 1}}
        else
          # The parent state (llm/model/system) — needed for the tool
          # spawn_agent which launches a child with its own conversation.
          tool_state = %{llm: llm, model: model, system: get_system(messages)}

          # The deepseek executionMode: parallel tool_calls start
          # together (Task.async_stream), exclusive ones form a barrier
          # and wait for the parallel group to empty (write, side-effects).
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

  # Executes the tool_calls respecting the executionMode (deepseek).
  # Groups :parallel together (concurrency), :exclusive as a barrier.
  # Results are reordered according to the ORIGINAL order of the calls (the
  # OpenAI API requires tool results in the same order as the tool_calls).
  defp execute_calls(calls, tool_state, trace, emit) do
    {parallel, exclusive} =
      Enum.split_with(calls, fn c -> Elixness.Tools.execution_mode(c.name) == :parallel end)

    {p_results, p_usage} = run_parallel(parallel, tool_state, 10, trace, emit)
    {e_results, e_usage} = run_parallel(exclusive, tool_state, 1, trace, emit)

    # Reorders by original call id to respect the model's order.
    by_id = Map.new(p_results ++ e_results, fn %{tool_call_id: id} = r -> {id, r} end)
    results = Enum.map(calls, fn c -> Map.fetch!(by_id, c.id) end)

    {results, sum_usage(p_usage, e_usage)}
  end

  # Runs a group of calls in parallel (bounded max_concurrency).
  defp run_parallel([], _tool_state, _max, _trace, _emit), do: {[], zero_usage()}

  defp run_parallel(calls, tool_state, max, trace, emit) do
    {results, usage} =
      calls
      |> Task.async_stream(
        fn call ->
          # Streaming: emits the tool start in REALTIME (if an emit pid is provided).
          if emit do
            send(emit, {:tool_start, call.name, truncate(call.arguments, 120)})
          end

          # Tracing: we measure the duration and log it (truncated args).
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
        # NO timeout — the 3 harnesses wait indefinitely for the
        # sub-agents to finish (opencode raceFirst, deepseek 0 timeout).
        timeout: :infinity,
        # on_stream_timeout: :kill_task — a child that exceeds (if we
        # ever re-add a timeout) is killed without killing the parent.
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(calls)
      |> Enum.map_reduce(zero_usage(), fn
        # Normal case: the tool returned a result.
        {{:ok, content}, call}, acc ->
          # The spawn returns {:result, content, child_usage} — we aggregate
          # the child's usage into the parent (the consumption of ALL agents).
          case content do
            {:result, text, usage} ->
              {%{role: "tool", tool_call_id: call.id, content: text}, sum_usage(acc, usage)}

            _ ->
              {%{role: "tool", tool_call_id: call.id, content: content}, acc}
          end

        # A child crashed (exception) — we do NOT kill the parent, we
        # send the error back to the model in the tool result.
        {{:exit, reason}, call}, acc ->
          {%{role: "tool", tool_call_id: call.id, content: "TOOL ERROR: #{inspect(reason)}"}, acc}

        # A child timed out (if a timeout is ever configured).
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
      "reasoning_tokens" => 0, "cache_read_tokens" => 0, "cost" => 0.0}
  end

  defp sum_usage(acc, usage) do
    %{
      "prompt_tokens" => (acc["prompt_tokens"] || 0) + (usage["prompt_tokens"] || 0),
      "completion_tokens" => (acc["completion_tokens"] || 0) + (usage["completion_tokens"] || 0),
      "total_tokens" => (acc["total_tokens"] || 0) + (usage["total_tokens"] || 0),
      "reasoning_tokens" => (acc["reasoning_tokens"] || 0) + (usage["reasoning_tokens"] || 0),
      "cache_read_tokens" => (acc["cache_read_tokens"] || 0) + (usage["cache_read_tokens"] || 0),
      "cost" => (acc["cost"] || 0.0) + (usage["cost"] || 0.0)
    }
  end
end
