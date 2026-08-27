defmodule Elixness.DiscoverTest do
  use ExUnit.Case, async: true

  alias Elixness.Discover

  describe "french?/1" do
    test "détecte le français (accents)" do
      assert Discover.french?("Témoignage anonymisé — le résumé")
    end

    test "détecte le français (stopwords)" do
      assert Discover.french?("Le formulaire de témoignage est pré-rempli avec le template")
    end

    test "rejette l'anglais" do
      refute Discover.french?("The list of a survey's testimonies — the entry view.")
      refute Discover.french?("How an agissement reads, everywhere it reads.")
    end
  end

  describe "scan/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "elixness_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib/fr"))
      File.mkdir_p!(Path.join(dir, "lib/en"))

      File.write!(
        Path.join(dir, "lib/fr/french.ex"),
        """
        defmodule French do
          @moduledoc \"\"\"
          Un moduledoc français avec des accents et des stopwords.
          \"\"\"

          def hello, do: :world
        end
        """
      )

      File.write!(
        Path.join(dir, "lib/en/english.ex"),
        """
        defmodule English do
          @moduledoc \"\"\"
          An English moduledoc, no accents.
          \"\"\"

          def hello, do: :world
        end
        """
      )

      File.write!(
        Path.join(dir, "lib/fr/single.ex"),
        """
        defmodule Single do
          @moduledoc "Un moduledoc français sur une seule ligne."

          def hello, do: :world
        end
        """
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "garde seulement les moduledoc français, avec line et delimiter", %{dir: dir} do
      jobs = Discover.scan(dir, limit: 10)

      assert length(jobs) == 2

      fr = Enum.find(jobs, &(&1.file =~ "french.ex"))
      assert fr.line == 2
      assert fr.delimiter == ~S(""")
      assert fr.text =~ "Un moduledoc français"

      single = Enum.find(jobs, &(&1.file =~ "single.ex"))
      assert single.delimiter == ~S(")
    end

    test "respecte limit", %{dir: dir} do
      assert length(Discover.scan(dir, limit: 1)) == 1
    end
  end
end
