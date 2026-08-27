defmodule Elixness.Discover do
  @moduledoc """
  Étape mécanique du flatmap : scanne `lib/**/*.ex`, parse les `@moduledoc`
  via `Code.string_to_quoted/1` (AST, pas de regex), garde ceux qui sentent
  le français, et estime la consommation de tokens (chars / 4).

  Un job = `%{file, text, line, column, delimiter, est_tokens}`.
  """

  # Instruction fixe du job : elle rentre dans la fenêtre de chaque agent.
  @instruction_est_tokens 110

  def scan(root, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # Si le path est déjà un dossier de code (sous lib/), on scanne tel quel.
    # Sinon (racine projet), on ajoute lib/. Évite "lib/lib/..." quand le
    # modèle passe un chemin comme lib/inductive/domain.
    pattern =
      if String.contains?(root, "lib/") or String.ends_with?(root, "lib") do
        Path.join(root, "**/*.ex")
      else
        Path.join(root, "lib/**/*.ex")
      end

    pattern
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, ["_build", "deps/"]))
    |> Enum.flat_map(&moduledocs/1)
    |> Enum.filter(&french?(&1.text))
    |> Enum.take(limit)
  end

  @doc "Estimation grossière des tokens d'un agent (instruction + texte)."
  def estimate_tokens(text) do
    @instruction_est_tokens + div(String.length(text), 4)
  end

  ## Extraction AST

  defp moduledocs(file) do
    with {:ok, content} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(content, columns: true, token_metadata: true) do
      ast
      |> collect()
      |> Enum.map(fn {text, meta} ->
        %{
          file: file,
          text: text,
          line: meta[:line],
          column: meta[:column],
          delimiter: meta[:delimiter] || ~S("),
          est_tokens: estimate_tokens(text)
        }
      end)
    else
      _ -> []
    end
  end

  # `@moduledoc "texte"` apparaît dans l'AST comme `{:@, _, [{:moduledoc, _, [val | _]}]}`.
  # Avec `token_metadata: true`, les littéraux chaîne sont `{:__block__, meta, [texte]}`
  # où meta porte delimiter/line/column.
  defp collect(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:moduledoc, mdoc_meta, [val | _]}]} = node, acc ->
          case string_literal(val) do
            {:ok, text, str_meta} ->
              # `token_metadata` n'enveloppe pas les heredocs ici : pas de
              # delimiter dans l'AST. Heuristique fiable : une valeur avec un
              # saut de ligne ne peut être qu'un heredoc (mix format convertit
              # tout moduledoc multi-lignes en `"""`).
              delimiter = if String.contains?(text, "\n"), do: ~S("""), else: ~S(")

              meta = %{
                line: str_meta[:line] || mdoc_meta[:line],
                column: str_meta[:column] || mdoc_meta[:column],
                delimiter: delimiter
              }

              {node, [{text, meta} | acc]}

            :error ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp string_literal(text) when is_binary(text), do: {:ok, text, %{}}
  defp string_literal({:__block__, meta, [text]}) when is_binary(text), do: {:ok, text, meta}
  defp string_literal(_), do: :error

  ## Détection du français

  @stopwords ["le ", "la ", "les ", "des ", "une ", "du ", "pour ", "avec ", "dans ", "sur ",
              "est ", "sont ", "pas ", "qui ", "que ", "ce ", "en ", "au ", "aux ", "de la "]

  def french?(text) do
    accents = Regex.match?(~r/[àâäéèêëîïôöùûüçœæ]/u, text)
    lower = String.downcase(text)
    count = Enum.count(@stopwords, &String.contains?(lower, &1))
    accents or count >= 2
  end
end
