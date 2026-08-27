defmodule Elixness.Inbox do
  @moduledoc """
  L'inbox du harness — le pattern next-turn/next-step de deepseek-harness,
  porté sur Elixir/Jido.

  Un GenServer dédié par agent (léger) tient la file de messages en attente.
  Le loop (`Elixness.Loop`) draine la file à chaque turn ; n'importe qui peut
  déposer un message entre les turns sans bloquer.

  API (sémantique deepseek) :
  - `followup(pid, msg)` : ajoute au prochain turn, réveille le loop.
  - `steer(pid, msg)` : ajoute au prochain step, réveille le loop.
  - `inject(pid, msg)` : ajoute au prochain step, SANS réveiller (le message
    attend que le loop soit réveillé par autre chose).
  - `drain(pid)` : retire tous les messages en attente (le loop les traite).
  """

  use GenServer

  ## API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{queue: :queue.new()}, opts)
  end

  @doc "Ajoute au prochain turn et réveille le loop."
  def followup(pid, msg) do
    GenServer.call(pid, {:push, msg, :turn})
  end

  @doc "Ajoute au prochain step et réveille le loop."
  def steer(pid, msg) do
    GenServer.call(pid, {:push, msg, :step})
  end

  @doc "Ajoute au prochain step SANS réveiller."
  def inject(pid, msg) do
    GenServer.call(pid, {:push, msg, :inject})
  end

  @doc "Retire tous les messages en attente. Retourne la liste."
  def drain(pid) do
    GenServer.call(pid, :drain)
  end

  @doc "Nombre de messages en attente."
  def size(pid) do
    GenServer.call(pid, :size)
  end

  ## GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:push, msg, kind}, _from, %{queue: q} = state) do
    # L'inject ne réveille pas : on le marque (le loop le voit au drain).
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
