defmodule Elixness.Jido do
  @moduledoc """
  Elixness's Jido instance. Agents run inside it (worker pool).
  """
  use Jido, otp_app: :elixness
end
