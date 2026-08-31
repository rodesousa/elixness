defmodule Elixness.Auth do
  @moduledoc """
  Reads the Nous credentials (OAuth of the Hermes account) from
  `~/.hermes/auth.json` — the file that `hermes` maintains at login.

  Overridable via `ELIXNESS_AUTH_PATH`. Only reads the `providers.nous`
  structure (access_token + inference_base_url).
  """

  @default_path Path.join(System.user_home(), ".hermes/auth.json")

  def default_path, do: @default_path

  @doc """
  Returns `{:ok, %{token: token, base_url: base_url, path: path}}`
  or `{:error, reason}`.
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
