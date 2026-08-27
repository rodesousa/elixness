defmodule Elixness.Jido do
  @moduledoc """
  Instance Jido d'elixness. Les agents tournent dedans (worker pool).
  """
  use Jido, otp_app: :elixness
end
