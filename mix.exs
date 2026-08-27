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

  # Jido a besoin de son app et Req de Finch pour l'HTTP.
  def application do
    [
      extra_applications: [:logger, :ssl, :inets, :crypto]
    ]
  end

  defp escript do
    [main_module: Elixness.CLI]
  end

  defp deps do
    [
      {:jido, "~> 2.3"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
