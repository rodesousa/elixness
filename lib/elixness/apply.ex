defmodule Elixness.Apply do
  @moduledoc """
  Writes the validated translations into the source files.

  Line-by-line replacement guided by the AST (line + delimiter): it
  replaces the `@moduledoc """..."""` block (or the `@moduledoc "..."` line)
  with the same block in English. Jobs for the same file are applied from
  bottom to top so that line numbers remain valid.
  """

  @doc """
  Applies a list of `%{file, line, delimiter, en}`.
  Returns the list of modified files.
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
  Replaces the `@moduledoc` block of a file's content (based on the job's
  `line` and `delimiter`) with the English version `en`.
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
