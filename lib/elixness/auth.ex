defmodule Elixness.Auth do
  @moduledoc """
  Lit les identifiants Nous (OAuth du compte Hermes) depuis
  `~/.hermes/auth.json` — le fichier que `hermes` maintient au login.

  Surchargeable via `ELIXNESS_AUTH_PATH`. Ne lit que la structure
  `providers.nous` (access_token + inference_base_url).
  """

  @default_path Path.join(System.user_home(), ".hermes/auth.json")

  def default_path, do: @default_path

  @doc """
  Retourne `{:ok, %{token: token, base_url: base_url, path: path}}`
  ou `{:error, raison}`.
  """
  def load do
    path = System.get_env("ELIXNESS_AUTH_PATH") || @default_path

    with true <- File.exists?(path),
         {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json),
         %{"access_token" => token, "inference_base_url" => base} when is_binary(token) <-
           get_in(data, ["providers", "nous"]) do
      if expired?(data) do
        IO.warn(
          "elixness: le token Hermes (auth.json) est peut-être expiré " <>
            "(expires_at passé) — l'API répondra 401. Relance `hermes` pour le rafraîchir."
        )
      end

      {:ok, %{token: token, base_url: String.trim_trailing(base, "/"), path: path}}
    else
      false -> {:error, {:auth_file_not_found, path}}
      {:error, _} = err -> err
      _ -> {:error, :nous_credentials_not_found}
    end
  end

  defp expired?(data) do
    case get_in(data, ["providers", "nous", "expires_at"]) do
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :lt
          _ -> false
        end

      _ ->
        false
    end
  end
end
