defmodule Elixness.ChildRegistry do
  @moduledoc """
  L'annuaire des enfants actifs — un `Agent` (état = map `child_id => %{child:, inbox:}`).

  C'est l'annuaire (qui est où) complémentaire de l'Inbox (la boîte).
  - `register` : enregistre un enfant spawné avec son inbox.
  - `lookup` : retrouve les pids d'un enfant.
  - `cancel` : tue un enfant proprement (`Process.exit(:shutdown)` — le
    pattern AbortController de deepseek, porté sur le BEAM).
  - `steer` : envoie une instruction à l'enfant via son inbox (le pattern
    next-step de deepseek).
  """

  use Agent

  @type child :: %{child: pid(), inbox: pid()}

  ## API

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts)
  end

  @doc "Enregistre un enfant sous `child_id`. Retourne `:ok`."
  def register(registry, child_id, %{child: child, inbox: inbox}) do
    Agent.update(registry, &Map.put(&1, child_id, %{child: child, inbox: inbox}))
  end

  @doc "Retrouve un enfant. `{:ok, %{child:, inbox:}}` ou `:error`."
  def lookup(registry, child_id) do
    case Agent.get(registry, &Map.get(&1, child_id)) do
      nil -> :error
      child -> {:ok, child}
    end
  end

  @doc "Liste les enfants actifs : `[{child_id, %{child:, inbox:}}]`."
  def list(registry) do
    Agent.get(registry, &Map.to_list/1)
  end

  @doc """
  Tue un enfant proprement (`Process.exit(:shutdown)` — les blocs `after`
  s'exécutent). Retourne `:ok` ou `{:error, :not_found}`.
  """
  def cancel(registry, child_id) do
    case Agent.get_and_update(registry, fn children ->
           {Map.get(children, child_id), Map.delete(children, child_id)}
         end) do
      nil ->
        {:error, :not_found}

      %{child: child} ->
        Process.exit(child, :shutdown)
        :ok
    end
  end

  @doc """
  Envoie une instruction à un enfant via son inbox (le steering deepseek).
  Retourne `:ok` ou `{:error, :not_found}`.
  """
  def steer(registry, child_id, message) do
    case lookup(registry, child_id) do
      {:ok, %{inbox: inbox}} ->
        Elixness.Inbox.steer(inbox, message)
        :ok

      :error ->
        {:error, :not_found}
    end
  end
end
