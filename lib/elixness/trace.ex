defmodule Elixness.Trace do
  @moduledoc """
  Tracing of tool_calls — the trace of an agent's actions.

  An `Agent` that records every executed tool_call: timestamp, tool name,
  arguments, result (truncated), duration, and identity (parent agent or
  child). It's the observability of the harness — see what the agents are
  doing live (the context-engineering flamegraph applied to tools).

  - `log/3`: records a tool_call.
  - `events/1`: the chronological list.
  - `summary/1`: a readable summary (per tool, counter, total duration).
  """

  use Agent

  @max_events 500

  ## API

  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, opts)
  end

  @doc "Records a tool_call. `%{time, agent, name, args, result, duration_ms}`."
  def log(trace, event) do
    Agent.update(trace, fn events ->
      [event | events] |> Enum.take(@max_events)
    end)
  end

  @doc "The list of events, from most recent to oldest. (pid only)"
  def events(trace) when is_pid(trace) do
    Agent.get(trace, & &1)
  end

  @doc "Summary: counter per tool + total duration. Accepts a pid OR an already-computed summary."
  def summary(%{events: _} = summary), do: summary
  def summary(trace), do: compute_summary(events(trace))

  defp compute_summary(events) do
    counts =
      Enum.frequencies_by(events, & &1.name)

    total_ms =
      Enum.reduce(events, 0, fn e, acc -> acc + (e.duration_ms || 0) end)

    %{
      total: length(events),
      counts: counts,
      total_ms: total_ms,
      events: events
    }
  end

  @doc "Readable display of the summary."
  def render_summary(trace) do
    %{total: total, counts: counts, total_ms: total_ms} = summary(trace)

    lines = ["TRACE: #{total} tool_call(s), #{total_ms}ms cumulés"]

    lines =
      lines ++
        Enum.map(counts, fn {name, n} ->
          "  #{name}: #{n}"
        end)

    Enum.join(lines, "\n")
  end
end
