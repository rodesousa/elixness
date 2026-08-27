defmodule Elixness.InboxRegistry do
  @moduledoc """
  Le registre des inbox actives — l'annuaire des boîtes aux lettres.

  Associe `fichier → pid de l'inbox` pour chaque job en cours, via un
  `Registry` (un ETS avec cycle de vie géré : le job qui meurt voit son
  entrée disparaître automatiquement). C'est ce qui permet le steering
  externe : `elixness steer <fichier> <message>` retrouve l'inbox d'un job
  en cours et y dépose un message, que le loop draine au turn suivant.
  """

  @registry :elixness_inboxes

  @doc "Démarre le Registry (à appeler au boot du CLI)."
  def start_link do
    Registry.start_link(keys: :unique, name: @registry)
  end

  @doc "Enregistre l'inbox d'un job, keyée par fichier. Retourne `:ok`."
  def register(file, inbox_pid) do
    # Registry.register retourne {:ok, pid} (pas :ok) — on normalise.
    {:ok, _} = Registry.register(@registry, file, inbox_pid)
    :ok
  end

  @doc "Retrouve l'inbox d'un fichier. `{:ok, pid}` ou `:error`."
  def lookup(file) do
    case Registry.lookup(@registry, file) do
      [{_, pid}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Liste les jobs en cours : `[{fichier, pid}]`."
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
  end
end
