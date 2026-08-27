defmodule Elixness.Trace do
  @moduledoc """
  Le traçage des tool_calls — la trace des actions d'un agent.

  Un `Agent` qui enregistre chaque tool_call exécuté : horodatage, nom du
  tool, arguments, résultat (tronqué), durée, et l'identité (agent parent ou
  child). C'est l'observabilité du harness — voir ce que font les agents en
  direct (le flamegraph de context-engineering appliqué aux tools).

  - `log/3` : enregistre un tool_call.
  - `events/1` : la liste chronologique.
  - `summary/1` : un résumé lisible (par tool, compteur, durée totale).
  """

  use Agent

  @max_events 500

  ## API

  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, opts)
  end

  @doc "Enregistre un tool_call. `%{time, agent, name, args, result, duration_ms}`."
  def log(trace, event) do
    Agent.update(trace, fn events ->
      [event | events] |> Enum.take(@max_events)
    end)
  end

  @doc "La liste des événements, du plus récent au plus ancien. (pid seulement)"
  def events(trace) when is_pid(trace) do
    Agent.get(trace, & &1)
  end

  @doc "Résumé : compteur par tool + durée totale. Accepte un pid OU un résumé déjà calculé."
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

  @doc "Affichage lisible du résumé."
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
