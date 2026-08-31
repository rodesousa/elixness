defmodule Elixness.Context do
  @moduledoc """
  The malloc transparency — assembles what goes to the LLM and counts the
  tokens per section (the context-engineering flamegraph, brought to life).

  Typical sections of a request:
  - `:system` : the system prompt (harness + instructions)
  - `:files` : the files selected into context (the chat dropdown)
  - `:conversation` : the exchanged messages
  - `:tools` : the tool schemas

  `estimate/1` gives the estimate BEFORE sending (chars / 4) ; the loop
  reports the real usage AFTER (the `usage` fields of the API). The
  estimated vs real difference is the lesson of the elixness experiment (A vs C).
  """

  @type section :: :system | :files | :conversation | :tools

  @doc """
  Assembles the messages to send to the LLM from a context description.

  Returns `%{messages: messages, sections: %{section => chars}}` where
  `sections` counts the characters of each section (for the estimate).
  """
  def assemble(opts) do
    system = Keyword.get(opts, :system, "")
    files = Keyword.get(opts, :files, []) |> List.wrap()
    conversation = Keyword.get(opts, :conversation, [])
    tools = Keyword.get(opts, :tools, [])

    # Final messages: system + files (user) + conversation
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
  Estimates the tokens of each section (chars / 4, the rough standard).
  Returns `%{section => tokens}` + `:total`.
  """
  def estimate(%{sections: sections}) do
    tokens =
      Map.new(sections, fn {section, chars} -> {section, div(chars, 4)} end)

    Map.put(tokens, :total, Enum.sum(Map.values(tokens)))
  end

  @doc """
  Displays the context flamegraph (breakdown per section + total).
  Plain text, ready to be rendered by the TUI or the terminal.
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
