defmodule Elixness.Reduce do
  @moduledoc """
  Étape reduce : collecte les fiches des agents map, agrège les tokens et
  mesure le gain de parallélisme (temps mural vs somme des latences — un
  proxy de ce qu'aurait coûté l'exécution séquentielle, sans l'appeler).
  """

  def run(results, started_mono) do
    wall_ms = System.monotonic_time(:millisecond) - started_mono
    ok = Enum.filter(results, & &1.ok)
    failed = Enum.filter(results, &(not &1.ok))

    totals = %{
      prompt: sum_tokens(ok, "prompt_tokens"),
      completion: sum_tokens(ok, "completion_tokens"),
      total: sum_tokens(ok, "total_tokens")
    }

    sum_latency = Enum.reduce(ok, 0, &(&1.latency_ms + &2))

    %{
      wall_ms: wall_ms,
      ok: ok,
      failed: failed,
      totals: totals,
      sum_latency: sum_latency
    }
  end

  defp sum_tokens(results, key) do
    Enum.reduce(results, 0, fn r, acc -> acc + (r.usage[key] || 0) end)
  end
end
