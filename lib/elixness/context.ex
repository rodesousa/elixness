defmodule Elixness.Context do
  @moduledoc """
  La transparence du malloc — assemble ce qui part au LLM et compte les
  tokens par section (le flamegraph de context-engineering, rendu vivant).

  Sections typiques d'un envoi :
  - `:system` : le system prompt (harness + instructions)
  - `:files` : les fichiers sélectionnés en contexte (le dropdown du chat)
  - `:conversation` : les messages échangés
  - `:tools` : les tool schemas

  `estimate/1` donne l'estimation AVANT l'envoi (chars / 4) ; le loop
  rapporte l'usage réel APRÈS (champs `usage` de l'API). La différence
  estimé vs réel est la leçon de l'expérience elixness (A vs C).
  """

  @type section :: :system | :files | :conversation | :tools

  @doc """
  Assemble les messages à envoyer au LLM depuis une description de contexte.

  Retourne `%{messages: messages, sections: %{section => chars}}` où
  `sections` compte les caractères de chaque section (pour l'estimation).
  """
  def assemble(opts) do
    system = Keyword.get(opts, :system, "")
    files = Keyword.get(opts, :files, []) |> List.wrap()
    conversation = Keyword.get(opts, :conversation, [])
    tools = Keyword.get(opts, :tools, [])

    # Les messages finaux : system + fichiers (user) + conversation
    file_messages =
      Enum.map(files, fn file ->
        content = if is_map(file), do: Map.get(file, :content, ""), else: file
        %{role: "user", content: content}
      end)

    system_chars = String.length(system)
    files_chars = Enum.reduce(file_messages, 0, &(&2 + String.length(&1.content)))
    conversation_chars = Enum.reduce(conversation, 0, &(&2 + String.length(to_string(&1.content || ""))))
    tools_chars = tools |> Jason.encode!() |> String.length()

    %{
      messages: [%{role: "system", content: system}] ++ file_messages ++ conversation,
      sections: %{
        system: system_chars,
        files: files_chars,
        conversation: conversation_chars,
        tools: tools_chars
      }
    }
  end

  @doc """
  Estime les tokens de chaque section (chars / 4, le standard grossier).
  Retourne `%{section => tokens}` + `:total`.
  """
  def estimate(%{sections: sections}) do
    tokens =
      Map.new(sections, fn {section, chars} -> {section, div(chars, 4)} end)

    Map.put(tokens, :total, Enum.sum(Map.values(tokens)))
  end

  @doc """
  Affiche le flamegraph de contexte (breakdown par section + total).
  Simple texte, prêt à être rendu par le TUI ou le terminal.
  """
  def flamegraph(%{sections: sections}, limit \\ 128_000) do
    est = estimate(%{sections: sections})
    width = 40

    lines =
      Enum.map([:system, :files, :conversation, :tools], fn section ->
        tokens = Map.get(est, section, 0)
        bar = bar(tokens, Map.get(est, :total), width)
        label = String.pad_trailing(to_string(section), 14)
        "#{label} #{String.pad_leading(Integer.to_string(tokens), 7)} tok  #{bar}"
      end)

    total = Map.get(est, :total)
    total_line = "TOTAL           #{String.pad_leading(Integer.to_string(total), 7)} / #{limit}"

    Enum.join(lines ++ [String.duplicate("─", 60), total_line], "\n")
  end

  defp bar(tokens, total, width) do
    filled = if total > 0, do: round(tokens / total * width), else: 0
    String.duplicate("█", min(filled, width)) <> String.duplicate("░", max(width - filled, 0))
  end
end
