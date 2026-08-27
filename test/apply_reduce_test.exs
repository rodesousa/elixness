defmodule Elixness.ApplyReduceTest do
  use ExUnit.Case, async: true

  alias Elixness.{Apply, Reduce}

  describe "Apply.replace/2 — heredoc" do
    test "remplace le contenu du moduledoc, garde les délimiteurs et l'indentation" do
      content = """
      defmodule Foo do
        @moduledoc \"\"\"
        Un texte français.
        Sur deux lignes.
        \"\"\"

        def bar, do: :ok
      end
      """

      job = %{
        line: 2,
        delimiter: ~S("""),
        en: "An English text." <> "\n" <> "On two lines."
      }

      result = Apply.replace(content, job)

      assert result =~ "An English text."
      assert result =~ "On two lines."
      assert result =~ ~S(@moduledoc """)
      assert result =~ ~S(""")

      assert result =~ "def bar, do: :ok"
      assert {:ok, _} = Code.string_to_quoted(result)
      refute result =~ "Un texte français"
    end

    test "échappe les guillemets d'un moduledoc mono-ligne" do
      content = """
      defmodule Foo do
        @moduledoc "Un texte français."

        def bar, do: :ok
      end
      """

      job = %{line: 2, en: "A quoted \"English\" text."}
      result = Apply.replace(content, job)
      assert result =~ ~S(@moduledoc "A quoted \"English\" text.")
      assert {:ok, _} = Code.string_to_quoted(result)
    end
  end

  describe "Apply.write/1" do
    test "écrit plusieurs jobs d'un même fichier (du bas vers le haut)" do
      dir = Path.join(System.tmp_dir!(), "elixness_apply_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file = Path.join(dir, "multi.ex")

      File.write!(file, """
      defmodule A do
        @moduledoc \"\"\"
        Texte A.
        \"\"\"
      end

      defmodule B do
        @moduledoc \"\"\"
        Texte B.
        \"\"\"
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      Apply.write([
        %{file: file, line: 2, delimiter: ~S("""), en: "Text A."},
        %{file: file, line: 9, delimiter: ~S("""), en: "Text B."}
      ])

      result = File.read!(file)
      assert result =~ "Text A."
      assert result =~ "Text B."
      refute result =~ "Texte A"
      refute result =~ "Texte B"
      assert {:ok, _} = Code.string_to_quoted(result)
    end
  end

  describe "Reduce.run/2" do
    test "agrège tokens et latences, sépare ok/failed" do
      started = System.monotonic_time(:millisecond)

      results = [
        %{ok: true, usage: %{"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}, latency_ms: 1000},
        %{ok: true, usage: %{"prompt_tokens" => 200, "completion_tokens" => 50, "total_tokens" => 250}, latency_ms: 2000},
        %{ok: false, usage: nil, latency_ms: 500, error: "boom"}
      ]

      r = Reduce.run(results, started)

      assert length(r.ok) == 2
      assert length(r.failed) == 1
      assert r.totals.prompt == 300
      assert r.totals.completion == 100
      assert r.totals.total == 400
      assert r.sum_latency == 3000
    end
  end
end
