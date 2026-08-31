defmodule Elixness.Catalog do
  @moduledoc """
  Le catalogue mécanique d'un repo — la table des matières.

  Zéro LLM : scanne les fichiers (`rg --files`) et extrait leurs ancres par
  regex selon le langage (module/def pour Elixir, export/class/function pour
  TS, def/class pour Python, titres pour Markdown) + le moduledoc de tête.

  Le modèle reçoit un bloc compact (~10-20k tokens pour 200 fichiers) et
  choisit QUOI LIRE au lieu d'analyser chaque fichier avec 1 appel LLM
  (le 666k tokens de explore_repo). C'est le pattern « chercher d'abord,
  lire ensuite » des 3 harness, en une passe mécanique.
  """

  # Extensions reconnues par famille.
  @elixir_ext [".ex", ".exs"]
  @ts_ext [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"]
  @py_ext [".py"]
  @md_ext [".md", ".mdx"]

  @max_symbols 12  # ancres max par fichier
  @max_files 1000  # garde-fou sur le nombre de fichiers catalogués
  @max_total_symbols 4000  # garde-fou global sur le nombre de lignes du catalogue

  @doc """
  Construit le catalogue de `path`.
  - `limit` : nombre max de fichiers (défaut `:all` = tous jusqu'à @max_files).
  Retourne `%{count:, files:, text:}` où `text` est le catalogue compact.
  """
  def run(path, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)
    take = if limit == :all, do: @max_files, else: limit

    files = discover_files(path) |> Enum.take(take)
    entries = Enum.map(files, &extract(&1, path))

    text = render(entries)

    %{count: length(entries), files: files, text: text}
  end

  ## Découverte — rg --files (même backbone qu'explore.ex)

  defp discover_files(path) do
    # Extensions SANS le point pour le glob (avec point dans {..} rg échoue).
    exts = (@elixir_ext ++ @ts_ext ++ @py_ext ++ @md_ext) |> Enum.map(&String.trim_leading(&1, ".")) |> Enum.join(",")
    glob = "*.{#{exts}}"

    case System.cmd("rg", ["--files", "-g", glob, path], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true)
      _ -> Path.join(path, "**/*.{#{exts}}") |> Path.wildcard()
    end
  end

  ## Extraction par fichier

  defp extract(file, root) do
    content =
      case File.read(file) do
        {:ok, c} -> sanitize_utf8(c)
        {:error, _} -> ""
      end

    bytes = byte_size(content)
    nlines = content |> String.split("\n") |> length()

    symbols =
      content
      |> extract_symbols(Path.extname(file))
      |> Enum.uniq()
      |> Enum.take(@max_symbols)

    %{rel: Path.relative_to(file, root), lines: nlines, bytes: bytes, symbols: symbols}
  end

  defp extract_symbols(content, ext) when ext in @elixir_ext, do: extract_elixir(content)
  defp extract_symbols(content, ext) when ext in @ts_ext, do: extract_ts(content)
  defp extract_symbols(content, ext) when ext in @py_ext, do: extract_python(content)
  defp extract_symbols(content, ext) when ext in @md_ext, do: extract_md(content)
  defp extract_symbols(_content, _ext), do: []

  ## Extracteurs par famille (regex légères, pas de LSP)

  defp extract_elixir(content) do
    moduledoc =
      case Regex.run(~r/@moduledoc\s*(?:"""[^\n]*\n\s*)?([^"\n]{5,120})/m, content) do
        [_, text] -> ["doc: #{String.trim(text)}"]
        _ -> []
      end

    mods = scan(content, ~r/^\s*defmodule\s+([A-Za-z_][\w.]*)/m, "module")
    defs = extract_defs(content)
    specs = scan(content, ~r/^\s*@spec\s+([a-zA-Z_][\w!?]*)/m, "@spec")
    types = scan(content, ~r/^\s*@type[p]?\s+([a-zA-Z_][\w!?]*)/m, "@type")

    moduledoc ++ mods ++ defs ++ specs ++ types
  end

  # def/defp avec ou sans arité — le groupe optional `(\/\d+)?` peut donner
  # 3 ou 4 captures selon qu'il participe ou pas.
  defp extract_defs(content) do
    Regex.scan(~r/^\s*def(p)?\s+([a-zA-Z_][\w!?]*)(\/\d+)?/m, content)
    |> Enum.map(fn
      [_, "p", name, arity] -> "defp #{name}#{arity || ""}"
      [_, _, name, arity] -> "def #{name}#{arity || ""}"
      [_, "p", name] -> "defp #{name}"
      [_, _, name] -> "def #{name}"
    end)
  end

  defp extract_ts(content) do
    exports = scan(content, ~r/^\s*export\s+default\s+([A-Za-z_$][\w$]*)/m, "export default")
    exports2 = scan(content, ~r/^\s*export\s+(?:declare\s+)?(?:abstract\s+)?(?:class|function|const|let|var|interface|type|enum|async\s+function)\s+([A-Za-z_$][\w$]*)/m, "export")
    classes = scan(content, ~r/^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/m, "class")
    fns = scan(content, ~r/^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/m, "fn")
    consts = scan(content, ~r/^\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*=/m, "const")
    ifaces = scan(content, ~r/^\s*(?:export\s+)?(?:interface|type)\s+([A-Za-z_$][\w$]*)/m, "type")

    exports ++ exports2 ++ classes ++ fns ++ consts ++ ifaces
  end

  defp extract_python(content) do
    doc =
      case Regex.run(~r/^(?:"""|''')\s*([^"'\\n]{5,120})/m, content) do
        [_, text] -> ["doc: #{String.trim(text)}"]
        _ -> []
      end

    defs = scan(content, ~r/^\s*def\s+([a-zA-Z_][\w]*)/m, "def")
    classes = scan(content, ~r/^\s*class\s+([a-zA-Z_][\w]*)/m, "class")

    doc ++ defs ++ classes
  end

  defp extract_md(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/^\#{1,4}\s/))
    |> Enum.take(@max_symbols)
    |> Enum.map(&String.trim/1)
  end

  ## Helpers

  # scan simple : extrait le groupe 1 de chaque match et le préfixe `label`.
  defp scan(content, re, label) when is_binary(label) do
    Regex.scan(re, content) |> Enum.map(fn [_full, g1] -> "#{label} #{String.trim(g1)}" end)
  end

  ## Rendu — le texte compact que le modèle voit

  defp render(entries) do
    header = "CATALOG (zero-LLM, #{length(entries)} fichiers):"

    body =
      entries
      |> Enum.map(fn e ->
        sym_lines = Enum.map(e.symbols, fn s -> "    #{s}" end)
        Enum.join(["  #{e.rel} (#{e.lines} l, #{format_size(e.bytes)})" | sym_lines], "\n")
      end)

    all = [header | body]

    # Garde-fou global : on ne renvoie jamais un catalogue énorme au modèle.
    if total_symbols(entries) > @max_total_symbols do
      all ++ ["", "(catalogue tronqué — #{@max_total_symbols} ancres max. Réduis le périmètre ou lis un sous-dossier.)"]
    else
      all
    end
    |> Enum.join("\n")
  end

  defp total_symbols(entries), do: entries |> Enum.map(&length(&1.symbols)) |> Enum.sum()

  defp format_size(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)}k"
  defp format_size(bytes), do: "#{bytes}b"

  defp sanitize_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      {:error, converted, _} -> converted
      converted -> converted
    end
  end
end
