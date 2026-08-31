defmodule Elixness.Catalog do
  @moduledoc """
  The mechanical catalog of a repo — the table of contents.

  Zero LLM: scans the files (`rg --files`) and extracts their anchors by
  regex according to language (module/def for Elixir, export/class/function
  for TS, def/class for Python, headings for Markdown) + the leading moduledoc.

  The model receives a compact block (~10-20k tokens for 200 files) and
  chooses WHAT TO READ instead of analyzing each file with 1 LLM call
  (explore_repo's 666k tokens). It's the « search first, read later »
  pattern of the 3 harnesses, in a single mechanical pass.
  """

  # Recognized extensions by family.
  @elixir_ext [".ex", ".exs"]
  @ts_ext [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"]
  @py_ext [".py"]
  @md_ext [".md", ".mdx"]

  @max_symbols 12  # max anchors per file
  @max_files 1000  # safeguard on the number of cataloged files
  @max_total_symbols 4000  # global safeguard on the number of catalog lines

  # Selector system prompt: the child that picks the files from the catalog.
  # Short and stable (cache-read) — the catalog lives in THIS child, not in
  # the chat.
  @select_system """
  You are a precise code explorer. A catalog of a repository is given below:
  one block per file (relative path, line count, size, extracted symbols/docstring).
  Read the QUESTION, then list the file paths that are RELEVANT to answer it.
  Return ONLY the relative file paths, one per line, exactly as shown in the catalog.
  No explanations, no markdown, no code fences. If nothing is relevant, reply exactly: NONE
  """

  @doc """
  Builds the catalog of `path`.
  - `limit`: max number of files (default `:all` = all up to @max_files).
  Returns `%{count:, files:, text:}` where `text` is the compact catalog.
  """
  def run(path, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)
    take = if limit == :all, do: @max_files, else: limit

    files = discover_files(path) |> Enum.take(take)
    entries = Enum.map(files, &extract(&1, path))

    text = render(entries)

    %{count: length(entries), files: files, text: text}
  end

  @doc """
  MECHANICAL selection of files relevant to `question`: builds the catalog
  (zero-LLM), then makes ONE LLM call with the catalog + the question in a
  child's context — the child returns the relevant paths, one per line. The
  catalog lives in THIS child (1 call), NOT in the chat conversation (which
  only keeps the list). Returns `%{selected: [absolute paths], count:, usage:}`.
  """
  def select(llm, model, question, path, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)
    catalog = run(path, limit: limit)

    prompt =
      "QUESTION: #{question}\n\nCATALOG:\n#{catalog.text}\n\n" <>
        "List the relevant file paths (one per line, as shown in the catalog). Reply NONE if nothing is relevant."

    messages = [
      %{role: "system", content: @select_system},
      %{role: "user", content: prompt}
    ]

    case Elixness.LLM.chat(llm, model, messages, tools: []) do
      {:ok, %{content: content, usage: usage}} when content != "" ->
        selected =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.upcase(&1) == "NONE"))
          |> Enum.map(fn p ->
            if Path.type(p) == :absolute, do: p, else: Path.join(path, p)
          end)
          |> Enum.filter(&File.regular?/1)
          |> Enum.uniq()

        %{selected: selected, count: catalog.count, usage: usage}

      _ ->
        %{selected: [], count: catalog.count, usage: zero_usage()}
    end
  end

  ## Discovery — rg --files (same backbone as explore.ex)

  defp discover_files(path) do
    # Extensions WITHOUT the dot for the glob (with a dot in {..} rg fails).
    exts = (@elixir_ext ++ @ts_ext ++ @py_ext ++ @md_ext) |> Enum.map(&String.trim_leading(&1, ".")) |> Enum.join(",")
    glob = "*.{#{exts}}"

    case System.cmd("rg", ["--files", "-g", glob, path], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true)
      _ -> Path.join(path, "**/*.{#{exts}}") |> Path.wildcard()
    end
  end

  ## Per-file extraction

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

  ## Extractors by family (light regexes, no LSP)

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

  # def/defp with or without arity — the optional `(\/\d+)?` group can yield
  # 3 or 4 captures depending on whether it participates.
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
      case Regex.run(~r/^(?:"""|''')\s*([^\n]{5,120})/m, content) do
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

  # simple scan: extracts group 1 of each match and prefixes `label`.
  defp scan(content, re, label) when is_binary(label) do
    Regex.scan(re, content) |> Enum.map(fn [_full, g1] -> "#{label} #{String.trim(g1)}" end)
  end

  ## Rendering — the compact text the model sees

  defp render(entries) do
    header = "CATALOG (zero-LLM, #{length(entries)} fichiers):"

    body =
      entries
      |> Enum.map(fn e ->
        sym_lines = Enum.map(e.symbols, fn s -> "    #{s}" end)
        Enum.join(["  #{e.rel} (#{e.lines} l, #{format_size(e.bytes)})" | sym_lines], "\n")
      end)

    all = [header | body]

    # Global safeguard: we never send an enormous catalog to the model.
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

  defp zero_usage do
    %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0,
      "reasoning_tokens" => 0, "cache_read_tokens" => 0, "cost" => 0.0}
  end

  defp sanitize_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      {:error, converted, _} -> converted
      converted -> converted
    end
  end
end
