defmodule Elixness.Discover do
  @moduledoc """
  Mechanical step of the flatmap: lists the `.ex` files in the directory.

  Generic — no coupling to a specific task (neither moduledoc, nor
  translation). A job = `%{file, text}` where `text` is the file's content
  (the model decides what to do with it).
  """

  def scan(root, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)

    # If the path is already a code directory (under lib/), scan it as is.
    # Otherwise (project root), add lib/. Avoids "lib/lib/..." when the
    # model passes a path like lib/inductive/domain.
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
