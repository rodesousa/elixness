defmodule Elixness.Discover do
  @moduledoc """
  Étape mécanique du flatmap : liste les fichiers `.ex` du dossier.

  Générique — aucun couplage à une tâche spécifique (ni moduledoc, ni
  traduction). Un job = `%{file, text}` où `text` est le contenu du fichier
  (le modèle décide quoi en faire).
  """

  def scan(root, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)

    # Si le path est déjà un dossier de code (sous lib/), on scanne tel quel.
    # Sinon (racine projet), on ajoute lib/. Évite "lib/lib/..." quand le
    # modèle passe un chemin comme lib/inductive/domain.
    pattern =
      if String.contains?(root, "lib/") or String.ends_with?(root, "lib") do
        Path.join(root, "**/*.ex")
      else
        Path.join(root, "lib/**/*.ex")
      end

    files =
      pattern
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, ["_build", "deps/"]))
      |> Enum.take(if(limit == :all, do: 10_000, else: limit))

    Enum.map(files, fn file ->
      %{
        file: file,
        text: read_safe(file)
      }
    end)
  end

  defp read_safe(file) do
    case File.read(file) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end
end
