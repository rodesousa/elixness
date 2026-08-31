defmodule Elixness do
  @moduledoc """
  Elixness — a first harness job: translating the French `@moduledoc`s of an
  Elixir project into English, by launching N Jido agents in parallel
  (flatmap pattern: one agent per doc, then reduce).

  Commands:
    elixness translate [--limit N] [--dry-run] [--apply] [--model M]

  Run from the root of the target project (e.g. `~/git/inductive`), it scans
  `lib/**/*.ex`, keeps N `@moduledoc`s that look French, translates them via
  the Nous API (OAuth token of the Hermes account in `~/.hermes/auth.json`),
  aggregates token consumption, and can write the files (apply).
  """
end
