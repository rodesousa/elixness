defmodule Elixness.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixness,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  # Jido needs its app, and Req needs Finch for HTTP.
  def application do
    [
      extra_applications: [:logger, :ssl, :inets, :crypto]
    ]
  end

  defp escript do
    # +B : désactive le break handler d'OTP (le menu "BREAK: (a)bort
    # (c)ontinue...") — Ctrl+C (SIGINT) tue alors le process directement,
    # au lieu d'afficher le menu qui "avale" le Ctrl+C pendant une réponse
    # longue (le chat ne quitte plus). C'est le comportement attendu d'un CLI.
    [main_module: Elixness.CLI, emulator_args: ["+B"]]
  end

  defp deps do
    [
      {:jido, "~> 2.3"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
