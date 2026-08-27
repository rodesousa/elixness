defmodule Elixness.DiscoverTest do
  use ExUnit.Case, async: true

  alias Elixness.Discover

  describe "scan/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "elixness_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(
        Path.join(dir, "lib/a.ex"),
        """
        defmodule A do
          @moduledoc \"\"\"
          Un moduledoc français.
          \"\"\"

          def hello, do: :world
        end
        """
      )

      File.write!(
        Path.join(dir, "lib/b.ex"),
        """
        defmodule B do
          @moduledoc \"\"\"
          An English moduledoc.
          \"\"\"

          def hello, do: :world
        end
        """
      )

      File.write!(
        Path.join(dir, "lib/not_code.txt"),
        "just text"
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "liste tous les fichiers .ex avec leur contenu (générique, pas de filtre FR)", %{dir: dir} do
      jobs = Discover.scan(dir, limit: :all)

      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.file =~ ".ex"))
      assert Enum.all?(jobs, &(&1.text =~ "defmodule"))
    end

    test "respecte limit", %{dir: dir} do
      assert length(Discover.scan(dir, limit: 1)) == 1
    end
  end
end
