defmodule Elixness.Tools do
  @moduledoc """
  Le registre d'outils d'elixness — le « plateau » du harness.

  Chaque outil a un schema OpenAI (`schemas/0`, envoyé au modèle) et un
  executor (`execute/1`, appelé par le loop quand le modèle décide de
  l'utiliser). Test G : on reproduit les outils que les agents Hermes
  utilisent réellement (read_file, write_file, search_files).
  """

  @doc """
  Le mode d'exécution de chaque tool — le `executionMode` de deepseek.
  `:parallel` : peut tourner en même temps que d'autres calls (read-only).
  `:exclusive` : barrière — attend que les calls en vol se vident
  (write avec side-effects, spawn qui modifie l'état).
  """
  def execution_mode("read_file"), do: :parallel
  def execution_mode("search_files"), do: :parallel
  def execution_mode("write_file"), do: :exclusive
  def execution_mode("spawn_agent"), do: :parallel
  def execution_mode("flatmap"), do: :exclusive
  def execution_mode("explore_repo"), do: :exclusive
  def execution_mode("edit"), do: :exclusive
  def execution_mode("glob"), do: :parallel
  def execution_mode("web_search"), do: :parallel
  def execution_mode("web_extract"), do: :parallel
  def execution_mode("terminal"), do: :exclusive
  def execution_mode(_), do: :exclusive

  @spec schemas() :: [map()]
  def schemas do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          "description" =>
            "Read a text file (or list a directory). Bounded like deepseek: returns numbered lines with offset/limit (default 2000 lines max), and a footer to continue. Use offset to paginate large files — do NOT read whole files at once.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string", "description" => "Absolute file path or directory"},
              "offset" => %{"type" => "integer", "description" => "1-based line to start from (default 1)"},
              "limit" => %{"type" => "integer", "description" => "Max lines to return (default 2000)"}
            },
            "required" => ["path"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "write_file",
          "description" => "Write content to a file, replacing existing content.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string", "description" => "Absolute file path"},
              "content" => %{"type" => "string", "description" => "Full content to write"}
            },
            "required" => ["path", "content"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "search_files",
          "description" => "Search file contents with a regex pattern. Returns matching lines.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "pattern" => %{"type" => "string", "description" => "Regex pattern"},
              "path" => %{"type" => "string", "description" => "Directory to search (default: cwd)"}
            },
            "required" => ["pattern"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "spawn_agent",
          "description" =>
            "Spawn a subagent with its own fresh conversation to do a task in parallel. " <>
              "Returns the subagent's final result. Use for independent subtasks.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "prompt" => %{"type" => "string", "description" => "The task for the subagent, self-contained"},
              "model" => %{"type" => "string", "description" => "Model to use (default: same as parent)"}
            },
            "required" => ["prompt"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "flatmap",
          "description" =>
            "Run a task across many files in parallel: the harness scans the directory, " <>
              "spawns ONE agent per file, and collects the results. Use when the user asks " <>
              "to process a whole directory (translate, review, analyze many files). " <>
              "You do NOT need to explore or count files yourself — just call this.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "task" => %{"type" => "string", "description" => "The task for each agent, e.g. translate the French docstrings to English"},
              "path" => %{"type" => "string", "description" => "Directory to scan (default: cwd)"},
              "limit" => %{"type" => "integer", "description" => "Max files to process (default 10)"}
            },
            "required" => ["task"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "edit",
          "description" => "Edit a file by replacing an exact substring (old_string → new_string). Returns the updated file or an error.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string", "description" => "Absolute file path"},
              "old_string" => %{"type" => "string", "description" => "Exact text to find and replace"},
              "new_string" => %{"type" => "string", "description" => "Replacement text"}
            },
            "required" => ["path", "old_string", "new_string"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "glob",
          "description" => "List files by name/pattern (e.g. **/*.ex). Returns matching paths.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "pattern" => %{"type" => "string", "description" => "Glob pattern, e.g. **/*.ex"},
              "path" => %{"type" => "string", "description" => "Directory to search (default: cwd)"}
            },
            "required" => ["pattern"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "web_search",
          "description" => "Search the web. Returns up to N results (title, url, description).",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string", "description" => "The search query"},
              "limit" => %{"type" => "integer", "description" => "Max results (default 5)"}
            },
            "required" => ["query"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "web_extract",
          "description" => "Extract readable text content from a URL (web page or PDF).",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{"type" => "string", "description" => "The URL to extract"}
            },
            "required" => ["url"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "terminal",
          "description" => "Run a shell command. Returns stdout/stderr and exit code.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "command" => %{"type" => "string", "description" => "The shell command to run"}
            },
            "required" => ["command"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "explore_repo",
          "description" =>
            "Explore a directory in parallel: the harness scans the files, spawns ONE agent per file to analyze it, and summarizes. Use when the user asks what's in a repo / what a codebase does / to find relevant files — do NOT read files one by one yourself, just call this.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "question" => %{"type" => "string", "description" => "The question to answer about the repo, e.g. 'what tools does opencode have?'"},
              "path" => %{"type" => "string", "description" => "Directory to explore (default: cwd)"},
              "limit" => %{"type" => "integer", "description" => "Max files to analyze (default 10)"}
            },
            "required" => ["question"]
          }
        }
      }
    ]
  end

  @doc """
  Exécute un tool_call `%{id, name, arguments}` (arguments = string JSON).
  Retourne le contenu du résultat (ce que le loop renvoie au modèle).
  """
  def execute(%{name: "read_file", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    # Le modèle peut utiliser `path` (schema elixness) ou `file` (nom Hermes)
    path = Map.get(decoded, "path") || Map.get(decoded, "file")
    offset = Map.get(decoded, "offset", 1)
    limit = Map.get(decoded, "limit", 2000)

    cond do
      # Un dossier → liste les entrées (pattern opencode).
      File.dir?(path) ->
        entries =
          path
          |> File.ls!()
          |> Enum.sort()
          |> Enum.map(fn e ->
            full = Path.join(path, e)
            if File.dir?(full), do: e <> "/", else: e
          end)
          |> Enum.take(100)

        "(directory) #{path}:\n" <> Enum.join(entries, "\n")

      File.regular?(path) ->
        case File.read(path) do
          {:ok, content} ->
            # Borné comme deepseek : lignes numérotées + footer de pagination.
            lines = String.split(content, "\n")
            total = length(lines)
            start_line = max(offset, 1)
            end_line = min(start_line + limit - 1, total)

            shown =
              lines
              |> Enum.slice((start_line - 1)..(end_line - 1)//1)
              |> Enum.with_index(start_line)
              |> Enum.map(fn {line, n} -> "#{n}: #{line}" end)
              |> Enum.join("\n")

            footer =
              if end_line < total do
                "\n(Showing lines #{start_line}-#{end_line} of #{total}. Use offset=#{end_line + 1} to continue.)"
              else
                ""
              end

            sanitize_utf8(shown <> footer)

          {:error, reason} ->
            "ERROR: cannot read #{path}: #{inspect(reason)}"
        end

      true ->
        "ERROR: #{path} is not a file or directory"
    end
  end

  def execute(%{name: "write_file", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    path = Map.get(decoded, "path") || Map.get(decoded, "file")
    content = Map.get(decoded, "content") || ""

    case File.write(path, content) do
      :ok -> "OK: wrote #{byte_size(content)} bytes to #{path}"
      {:error, reason} -> "ERROR: cannot write #{path}: #{inspect(reason)}"
    end
  end

  def execute(%{name: "search_files", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    pattern = Map.get(decoded, "pattern") || "."
    path = Map.get(decoded, "path", ".")
    include = Map.get(decoded, "include")
    limit = Map.get(decoded, "limit", 100)

    # Moteur ripgrep (pattern opencode) : rapide, respecte .gitignore, saute
    # les binaires. Format de sortie groupé par fichier, truncation à `limit`.
    args =
      ["--line-number", "--no-heading", "-m", Integer.to_string(limit), pattern, path] ++
        if(include, do: ["-g", include], else: [])

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {out, 0} ->
        format_rg_results(out, limit)

      {out, 1} ->
        if String.contains?(out, "error") do
          "ERROR: rg #{String.trim(out)}"
        else
          "No matches for #{pattern} in #{path}"
        end

      {out, code} ->
        "ERROR: rg exit #{code}: #{String.slice(out, 0, 200)}"
    end
  end

  def execute(%{name: "edit", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    path = Map.get(decoded, "path")
    old_string = Map.get(decoded, "old_string", "")
    new_string = Map.get(decoded, "new_string", "")

    with {:ok, content} <- File.read(path),
         true <- String.contains?(content, old_string),
         :ok <- File.write(path, String.replace(content, old_string, new_string, global: false)) do
      "OK: replaced in #{path}"
    else
      false -> "ERROR: old_string not found in #{path}"
      {:error, reason} -> "ERROR: #{inspect(reason)}"
      _ -> "ERROR: could not edit #{path}"
    end
  end

  def execute(%{name: "glob", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    pattern = Map.get(decoded, "pattern", "**/*")
    path = Map.get(decoded, "path", ".")

    path
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, ["_build", "deps/", ".git"]))
    |> Enum.take(50)
    |> case do
      [] -> "No files matching #{pattern} in #{path}"
      files -> Enum.join(files, "\n")
    end
  end

  def execute(%{name: "web_search", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    query = Map.get(decoded, "query", "")
    limit = Map.get(decoded, "limit", 5)

    # Backend de recherche : DuckDuckGo HTML (gratuit, sans clé).
    url = "https://html.duckduckgo.com/html/?q=" <> URI.encode_www_form(query)

    case Req.get(url, headers: [{"user-agent", "elixness-agent"}]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        results = parse_ddg_results(body) |> Enum.take(limit)
        if results == [] do
          "No web results for #{query}"
        else
          Enum.join(results, "\n")
        end

      {:ok, %Req.Response{status: status}} ->
        "ERROR: web_search HTTP #{status}"

      {:error, reason} ->
        "ERROR: web_search #{inspect(reason)}"
    end
  end

  def execute(%{name: "web_extract", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    url = Map.get(decoded, "url", "")

    case Req.get(url, headers: [{"user-agent", "elixness-agent"}]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        # Extrait le texte lisible (grossier : retire les balises HTML).
        text =
          body
          |> String.replace(~r/<script[\s\S]*?<\/script>/i, " ")
          |> String.replace(~r/<style[\s\S]*?<\/style>/i, " ")
          |> String.replace(~r/<[^>]+>/, " ")
          |> String.replace(~r/\s+/, " ")
          |> String.slice(0, 6000)

        text

      {:ok, %Req.Response{status: status}} ->
        "ERROR: web_extract HTTP #{status}"

      {:error, reason} ->
        "ERROR: web_extract #{inspect(reason)}"
    end
  end

  def execute(%{name: "terminal", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    command = Map.get(decoded, "command", "")

    case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> "EXIT #{code}: #{out}"
    end
  end

  def execute(%{name: "explore_repo", arguments: args}) do
    %{} = decoded = Jason.decode!(args)
    question = Map.get(decoded, "question", "")
    path = Map.get(decoded, "path", ".")
    limit = Map.get(decoded, "limit", 10)

    result = Elixness.Explore.run(path, question, limit: limit)

    lines = ["EXPLORE_REPO RESULT: #{result.count} fichiers analysés (#{length(result.ok)} OK, #{length(result.errors)} erreurs)."]

    lines =
      lines ++
        Enum.map(result.errors, fn err -> "  ✗ #{inspect(err)}" end)

    lines =
      lines ++
        [
          "TOTAL usage: prompt=#{result.usage["prompt_tokens"]} completion=#{result.usage["completion_tokens"]} " <>
            "cost=#{result.usage["cost"]}"
        ]

    Enum.join(lines, "\n") <> "\n\n" <> result.summary
  end

  def execute(%{name: name}), do: "ERROR: unknown tool #{name}"

  # Formate la sortie rg comme opencode : "Found N matches" + groupé par fichier.
  defp format_rg_results(out, limit) do
    lines = out |> String.split("\n", trim: true)

    # Les lignes rg : "path:line:text" — on groupe par fichier.
    rows =
      lines
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, line_no, text] -> {file, line_no, String.trim(text)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    total = length(rows)
    has_more = total >= limit
    output = ["Found #{total} matches#{if has_more, do: " (more matches available)"}"]

    {_current, output} =
      Enum.reduce(rows, {"", output}, fn {file, line_no, text}, {cur, acc} ->
        acc =
          if file != cur and cur != "" do
            acc ++ [""]
          else
            acc
          end

        acc =
          if file != cur do
            acc ++ ["#{file}:"] ++ ["  Line #{line_no}: #{text}"]
          else
            acc ++ ["  Line #{line_no}: #{text}"]
          end

        {file, acc}
      end)

    if has_more do
      output ++ ["", "(Results truncated. Consider using a more specific path or pattern.)"]
    else
      output
    end
    |> Enum.join("\n")
  end

  # Parse les résultats de DuckDuckGo HTML (liens .result__a).
  defp parse_ddg_results(body) do
    # Les liens de résultat ont class="result__a" et href="//duckduckgo.com/l/?uddg=<encodé>"
    title_re = ~r/class="result__a"[^>]*>(.*?)<\/a>/
    href_re = ~r/class="result__a"[^>]*href="([^"]*)"/
    snip_re = ~r/class="result__snippet"[^>]*>(.*?)<\/a>/

    titles = Regex.scan(title_re, body) |> Enum.map(fn [_, t] -> strip_html(t) end)
    hrefs = Regex.scan(href_re, body) |> Enum.map(fn [_, h] -> h end)
    snips = Regex.scan(snip_re, body) |> Enum.map(fn [_, s] -> strip_html(s) end)

    titles
    |> Enum.zip(hrefs)
    |> Enum.zip(snips)
    |> Enum.map(fn {{title, href}, snip} ->
      url = decode_ddg_url(href)
      "#{title}\n  #{url}\n  #{snip}"
    end)
  end

  defp strip_html(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#x27;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace(~r/<[^>]+>/, "")
  end

  # L'URL DuckDuckGo est https://duckduckgo.com/l/?uddg=<url encodée> — on extrait le vrai lien.
  defp decode_ddg_url(href) do
    case URI.decode_query(String.trim_leading(href, "//duckduckgo.com/l/?")["uddg"] || "") do
      "" -> href
      url -> url
    end
  rescue
    _ -> href
  end

  # Remplace les octets invalides par U+FFFD.
  defp sanitize_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      {:error, converted, _} -> converted
      converted -> converted
    end
  end

  @doc """
  Exécute un tool_call `%{id, name, arguments}` avec l'état du loop
  (llm/model/system — nécessaire pour spawn_agent). Les tools simples
  (read/write/search) délèguent à `execute/1`.
  """
  def execute(call, %{llm: llm, model: model, system: system}) do
    case call.name do
      "spawn_agent" -> execute_spawn(call.arguments, llm, model, system)
      "flatmap" -> execute_flatmap(call.arguments, llm, model, system)
      _ -> execute(call)
    end
  end

  def execute(%{name: name}, _state), do: "ERROR: unknown tool #{name}"

  # Le flatmap mécanique : Discover → spawn 1 agent/fichier → collecte.
  # Retourne le résumé que le modèle voit (pas l'historique des agents).
  defp execute_flatmap(args, _llm, model, system) do
    %{} = decoded = Jason.decode!(args)
    task = Map.get(decoded, "task", "")
    path = Map.get(decoded, "path", File.cwd!())
    limit = Map.get(decoded, "limit", 10)

    result =
      Elixness.Flatmap.run(path, task,
        limit: limit,
        model: model,
        system: system
      )

    {:result, Elixness.Flatmap.summarize(result), result.usage}
  end

  defp execute_spawn(args, llm, model, system) do
    %{} = decoded = Jason.decode!(args)
    prompt = Map.get(decoded, "prompt", "")
    model = Map.get(decoded, "model") || model

    # Le child a sa propre conversation (system + prompt), zéro historique
    # parent — ET une inbox (pour le steering + l'annulation). Il est
    # enregistré dans le ChildRegistry sous un UUID (l'identité de session).
    child_id = "child-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, inbox} = Elixness.Inbox.start_link()

    task =
      Task.async(fn ->
        Elixness.Loop.run(llm, model, system, prompt, tools: Elixness.Tools.schemas(), inbox: inbox)
      end)

    Elixness.ChildRegistry.register(Elixness.ChildRegistry, child_id, %{
      child: task.pid,
      inbox: inbox
    })

    case Task.await(task, :infinity) do
      {:ok, content, %{usage: usage}} ->
        {:result, "SUBAGENT RESULT (#{child_id}): #{content}", usage}

      {:error, reason} ->
        {:result, "SUBAGENT ERROR (#{child_id}): #{inspect(reason)}", zero_usage()}
    end
  end

  defp zero_usage do
    %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0,
      "reasoning_tokens" => 0, "cost" => 0.0}
  end
end
