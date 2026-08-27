import Config

# Instance Jido — le pool d'agents est passé au démarrage (run-time),
# pas ici : il dépend du token Hermes lu depuis auth.json.
config :elixness, Elixness.Jido,
  max_tasks: 1000,
  agent_pools: []

# Le timeout d'exécution d'une action (appel LLM) : le défaut de jido_action
# est 30s, trop court pour un appel LLM. Aligné sur call_timeout du CLI.
config :jido_action, default_timeout: 120_000
