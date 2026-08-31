defmodule Elixness.Inbox do
  @moduledoc """
  The harness inbox — the next-turn/next-step pattern from deepseek-harness,
  ported to Elixir/Jido.

  A dedicated (lightweight) GenServer per agent holds the queue of pending messages.
  The loop (`Elixness.Loop`) drains the queue at each turn; anyone can
  drop a message between turns without blocking.

  API (deepseek semantics):
  - `followup(pid, msg)`: adds to the next turn, wakes the loop.
  - `steer(pid, msg)`: adds to the next step, wakes the loop.
  - `inject(pid, msg)`: adds to the next step WITHOUT waking (the message
    waits for the loop to be woken by something else).
  - `drain(pid)`: removes all pending messages (the loop processes them).
  """

  use GenServer

  ## API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{queue: :queue.new()}, opts)
  end

  @doc "Adds to the next turn and wakes the loop."
  def followup(pid, msg) do
    GenServer.call(pid, {:push, msg, :turn})
  end

  @doc "Adds to the next step and wakes the loop."
  def steer(pid, msg) do
    GenServer.call(pid, {:push, msg, :step})
  end

  @doc "Adds to the next step WITHOUT waking."
  def inject(pid, msg) do
    GenServer.call(pid, {:push, msg, :inject})
  end

  @doc "Removes all pending messages. Returns the list."
  def drain(pid) do
    GenServer.call(pid, :drain)
  end

  @doc "Number of pending messages."
  def size(pid) do
    GenServer.call(pid, :size)
  end

  ## GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:push, msg, kind}, _from, %{queue: q} = state) do
    # Inject does not wake: it is marked (the loop sees it at drain).
    {:reply, :ok, %{state | queue: :queue.in({msg, kind}, q)}}
  end

  def handle_call(:drain, _from, %{queue: q} = state) do
    messages = :queue.to_list(q)
    {:reply, messages, %{state | queue: :queue.new()}}
  end

  def handle_call(:size, _from, %{queue: q} = state) do
    {:reply, :queue.len(q), state}
  end
end
