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
  def execution_mode(_), do: :exclusive

  @spec schemas() :: [map()]
  def schemas do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          "description" => "Read a text file from disk. Returns the file content.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string", "description" => "Absolute file path"}
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

    case File.read(path) do
      {:ok, content} ->
        # Certains fichiers contiennent des octets non-UTF8 — on sanitize
        # (sinon Jason crashe en encodant le body de la requête LLM).
        if String.valid?(content) do
          content
        else
          sanitize_utf8(content)
        end

      {:error, reason} ->
        "ERROR: cannot read #{path}: #{inspect(reason)}"
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

    # Le modèle peut donner une regex OU une simple chaîne (ex. "." pour tout,
    # ou "moduledoc" pour chercher le mot). On compile en regex si possible,
    # sinon on retombe sur une recherche de sous-chaîne.
    regex =
      try do
        Regex.compile!(pattern)
      rescue
        _ -> nil
      end

    results =
      path
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.flat_map(fn f ->
        case File.read(f) do
          {:ok, content} ->
            content
            |> String.split("\n")
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} ->
              if regex, do: Regex.match?(regex, line), else: String.contains?(line, pattern)
            end)
            |> Enum.map(fn {line, n} -> "#{f}:#{n}: #{String.trim(line)}" end)

          {:error, _} ->
            []
        end
      end)
      |> Enum.take(20)

    if results == [] do
      "No matches for #{pattern} in #{path}"
    else
      Enum.join(results, "\n")
    end
  end

  def execute(%{name: name}), do: "ERROR: unknown tool #{name}"

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
        Elixness.Loop.run(llm, model, system, prompt, Elixness.Tools.schemas(), inbox)
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
