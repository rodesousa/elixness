defmodule Elixness.Apply do
  @moduledoc """
  Écrit les traductions validées dans les fichiers sources.

  Remplacement ligne-par-ligne guidé par l'AST (line + delimiter) : on
  remplace le bloc `@moduledoc """..."""` (ou la ligne `@moduledoc "..."`)
  par le même bloc en anglais. Les jobs d'un même fichier sont appliqués de
  bas en haut pour que les numéros de ligne restent valides.
  """

  @doc """
  Applique une liste de `%{file, line, delimiter, en}`.
  Retourne la liste des fichiers modifiés.
  """
  def write(jobs) do
    jobs
    |> Enum.group_by(& &1.file)
    |> Enum.map(fn {file, file_jobs} ->
      content = File.read!(file)
      sorted = Enum.sort_by(file_jobs, & &1.line, :desc)
      new_content = Enum.reduce(sorted, content, &replace(&2, &1))
      File.write!(file, new_content)
      file
    end)
  end

  @doc """
  Remplace le bloc `@moduledoc` d'un contenu de fichier (d'après `line` et
  `delimiter` du job) par la version anglaise `en`.
  """
  def replace(content, %{line: line, delimiter: ~S("""), en: en}) do
    lines = String.split(content, "\n")
    start_idx = line - 1

    end_idx =
      Enum.find_index(Enum.slice(lines, start_idx + 1..-1//1), fn l ->
        String.trim(l) == ~S(""")
      end)

    if end_idx do
      end_idx = start_idx + 1 + end_idx
      indent = String.slice(lines |> Enum.at(start_idx), 0, leading_spaces(lines |> Enum.at(start_idx)))

      body =
        en
        |> String.trim_trailing()
        |> String.split("\n")
        |> Enum.map(&(indent <> &1))

      replacement = [indent <> "@moduledoc \"\"\"", body, indent <> ~S(""")]
      before = Enum.slice(lines, 0, start_idx)
      tail = Enum.slice(lines, end_idx + 1, length(lines))
      Enum.concat([before, replacement, tail]) |> Enum.join("\n")
    else
      content
    end
  end

  def replace(content, %{line: line, en: en}) do
    lines = String.split(content, "\n")
    idx = line - 1
    indent = String.slice(Enum.at(lines, idx), 0, leading_spaces(Enum.at(lines, idx)))
    escaped = String.replace(en, "\\", "\\\\")
    escaped = String.replace(escaped, "\"", "\\\"")
    List.replace_at(lines, idx, indent <> "@moduledoc " <> "\"" <> escaped <> "\"") |> Enum.join("\n")
  end

  defp leading_spaces(line) do
    case Regex.run(~r/^\s*/, line || "") do
      [spaces] -> String.length(spaces)
      _ -> 0
    end
  end
end
