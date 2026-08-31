defmodule Elixness.ChildRegistry do
  @moduledoc """
  The directory of active children — an `Agent` (state = map `child_id => %{child:, inbox:}`).

  It's the directory (who is where) complementary to the Inbox (the mailbox).
  - `register`: registers a spawned child with its inbox.
  - `lookup`: finds a child's pids.
  - `cancel`: kills a child cleanly (`Process.exit(:shutdown)` — deepseek's
    AbortController pattern, ported to the BEAM).
  - `steer`: sends an instruction to a child via its inbox (deepseek's
    next-step pattern).
  """

  use Agent

  @type child :: %{child: pid(), inbox: pid()}

  ## API

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts)
  end

  @doc "Registers a child under `child_id`. Returns `:ok`."
  def register(registry, child_id, %{child: child, inbox: inbox}) do
    Agent.update(registry, &Map.put(&1, child_id, %{child: child, inbox: inbox}))
  end

  @doc "Finds a child. `{:ok, %{child:, inbox:}}` or `:error`."
  def lookup(registry, child_id) do
    case Agent.get(registry, &Map.get(&1, child_id)) do
      nil -> :error
      child -> {:ok, child}
    end
  end

  @doc "Lists active children: `[{child_id, %{child:, inbox:}}]`."
  def list(registry) do
    Agent.get(registry, &Map.to_list/1)
  end

  @doc """
  Kills a child cleanly (`Process.exit(:shutdown)` — `after` blocks run).
  Returns `:ok` or `{:error, :not_found}`.
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
  Sends an instruction to a child via its inbox (deepseek steering).
  Returns `:ok` or `{:error, :not_found}`.
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
