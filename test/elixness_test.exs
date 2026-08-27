defmodule ElixnessTest do
  use ExUnit.Case, async: true

  test "le modèle par défaut est celui du compte Hermes (surchargeable)" do
    model = Elixness.LLM.default_model()
    assert is_binary(model)
    assert model != ""
    assert Elixness.LLM.instruction() =~ "coding agent"
  end
end
