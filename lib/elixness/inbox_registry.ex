defmodule Elixness.InboxRegistry do
  @moduledoc """
  The registry of active inboxes — the directory of mailboxes.

  Associates `file → inbox pid` for each running job, via a
  `Registry` (an ETS with a managed lifecycle: when a job dies, its
  entry disappears automatically). This is what enables external
  steering: `elixness steer <file> <message>` finds the inbox of a
  running job and drops a message into it, which the loop drains at the
  next turn.
  """

  @registry :elixness_inboxes

  @doc "Starts the Registry (to be called at CLI boot)."
  def start_link do
    Registry.start_link(keys: :unique, name: @registry)
  end

  @doc "Registers a job's inbox, keyed by file. Returns `:ok`."
  def register(file, inbox_pid) do
    # Registry.register returns {:ok, pid} (not :ok) — we normalize.
    {:ok, _} = Registry.register(@registry, file, inbox_pid)
    :ok
  end

  @doc "Finds a file's inbox. `{:ok, pid}` or `:error`."
  def lookup(file) do
    case Registry.lookup(@registry, file) do
      [{_, pid}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Lists running jobs: `[{file, pid}]`."
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
  end
end
