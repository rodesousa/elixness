import Config

# Jido instance — the agent pool is passed at startup (run-time),
# not here: it depends on the Hermes token read from auth.json.
config :elixness, Elixness.Jido,
  max_tasks: 1000,
  agent_pools: []

# Execution timeout of an action (LLM call): jido_action's default is 30s,
# too short for an LLM call. Aligned with the CLI's call_timeout.
config :jido_action, default_timeout: 120_000
