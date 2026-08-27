defmodule Elixness do
  @moduledoc """
  Elixness — un premier job de harness : traduire les `@moduledoc` français
  d'un projet Elixir en anglais, en lançant N agents Jido en parallèle
  (pattern flatmap : un agent par doc, puis reduce).

  Commandes :
    elixness translate [--limit N] [--dry-run] [--apply] [--model M]

  Lancé depuis la racine du projet cible (ex. `~/git/inductive`), il scanne
  `lib/**/*.ex`, garde N `@moduledoc` qui sentent le français, les traduit
  via l'API Nous (token OAuth du compte Hermes dans `~/.hermes/auth.json`),
  agrège la consommation de tokens, et peut écrire les fichiers (apply).
  """
end
