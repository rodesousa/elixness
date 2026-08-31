defmodule Elixness.LineEditor do
  @moduledoc """
  Éditeur de ligne minimal pour le prompt du chat : flèches ←/→, ↑/↓
  (historique), Backspace, Suppr, Home/End, **Ctrl+W** (efface le mot avant
  le curseur), **Shift+Entrée** (saut de ligne multi-ligne, via le protocole
  clavier kitty `CSI u`), Ctrl+J (saut de ligne de secours), Entrée (envoyer),
  Ctrl+C/D (quitter).

  `IO.gets` n'a pas d'édition de ligne : les flèches arrivent en séquences
  d'échappement (`\\e[D`) affichées littéralement (`^[[D`). Ce module passe le
  terminal en mode raw (`stty raw -echo`), lit les touches une à une et gère
  l'édition + le rendu multi-ligne ANSI. Retombe sur `IO.gets` si stdin n'est
  pas un terminal (tests / pipe : `echo "msg" | elixness chat`).
  """

  @esc 27
  @ctrl_c 3
  @ctrl_d 4
  @ctrl_w 23
  @ctrl_j 10  # linefeed : saut de ligne de secours (distinct d'Entrée = \r)
  @backspace 127
  @ctrl_h 8
  @cr 13

  @doc """
  Lit une ligne avec édition. Retourne :
    - `:eof` — Ctrl+D sur ligne vide / EOF réel
    - `{:error, _}` — échec du terminal
    - la ligne (binary, sans `\\n` final) — Entrée
  `history` : liste des lignes précédentes (plus récente en tête), pour ↑/↓.
  """
  def read(prompt, history \\ []) do
    if tty?() do
      raw_read(prompt, history)
    else
      case IO.gets(prompt) do
        :eof -> :eof
        {:error, _} = err -> err
        line -> line
      end
    end
  end

  ## -- mode raw (stty via le fd 0 du VM = le vrai terminal) --

  defp tty? do
    case System.cmd("sh", ["-c", "test -t 0 < /proc/$PPID/fd/0 && echo yes"]) do
      {"yes\n", 0} -> true
      _ -> false
    end
  end

  defp save_termios do
    case System.cmd("sh", ["-c", "stty -g < /proc/$PPID/fd/0"]) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp restore_termios(saved) when is_binary(saved) do
    System.cmd("sh", ["-c", "stty '#{saved}' < /proc/$PPID/fd/0"])
    :ok
  end

  defp restore_termios(_), do: :ok

  defp raw_read(prompt, history) do
    saved = save_termios()
    System.cmd("sh", ["-c", "stty raw -echo < /proc/$PPID/fd/0"])
    :ok = :io.setopts(:standard_io, encoding: :unicode)
    enable_kitty_protocol()
    IO.write(prompt)

    result =
      try do
        edit_loop(%{buf: [], cursor: 0, hist: history, future: []}, prompt)
      after
        disable_kitty_protocol()
        restore_termios(saved)
        :io.setopts(:standard_io, encoding: :unicode)
        IO.write("\r\n")
      end

    case result do
      {:ok, line} -> line
      other -> other
    end
  end

  # Protocole clavier kitty (CSI u, mode 1 = désambiguïsation) : le terminal
  # envoie alors `\e[13;2u` pour Shift+Entrée, `\e[13;5u` pour Ctrl+Entrée, etc.
  # Les terminaux qui ne le supportent pas l'ignorent (Shift+Entrée = Entrée).
  defp enable_kitty_protocol, do: IO.write("\e[>1u")
  defp disable_kitty_protocol, do: IO.write("\e[<1u")

  ## -- lecture des touches --

  defp read_char do
    case IO.getn("", 1) do
      :eof -> :eof
      bin when is_binary(bin) and byte_size(bin) > 0 -> bin
      _ -> :eof
    end
  end

  # Retourne :eof | :up | :down | :left | :right | :home | :end | :delete |
  #          :shift_enter | :ignore | {:char, binary}
  defp read_key do
    case read_char() do
      :eof -> :eof
      <<@esc>> -> read_escape()
      ch -> {:char, ch}
    end
  end

  # Après ESC : soit une séquence CSI (flèches etc.), soit un simple ESC.
  defp read_escape do
    case read_char() do
      <<"[">> -> read_csi()
      <<"O">> -> read_ss3()
      _ -> :ignore
    end
  end

  # CSI : \e[ <params> <final>. On lit jusqu'à la lettre finale (ou ~).
  defp read_csi do
    case read_until_final("") do
      nil -> :ignore
      {:ok, params, final} -> interpret_csi(params, final)
    end
  end

  defp read_until_final(acc) do
    case read_char() do
      :eof -> nil
      <<c>> when c in ?A..?Z or c in ?a..?z or c == ?~ ->
        {:ok, acc, <<c>>}
      ch when is_binary(ch) ->
        read_until_final(acc <> ch)
    end
  end

  defp interpret_csi(_params, "A"), do: :up
  defp interpret_csi(_params, "B"), do: :down
  defp interpret_csi(_params, "C"), do: :right
  defp interpret_csi(_params, "D"), do: :left
  defp interpret_csi(_params, "H"), do: :home
  defp interpret_csi(_params, "F"), do: :end

  defp interpret_csi("3", "~"), do: :delete
  defp interpret_csi("1", "~"), do: :home
  defp interpret_csi("4", "~"), do: :end

  # CSI u (protocole kitty) : \e[<code>;<modifier>u
  defp interpret_csi(params, "u") when params != "" do
    [code, mod | _] = params |> String.split(";") |> Enum.map(&String.to_integer/1)
    case {code, mod} do
      {13, _} -> :shift_enter   # Shift/Alt/Ctrl+Entrée → saut de ligne
      _ -> :ignore
    end
  end

  defp interpret_csi(_, _), do: :ignore

  # SS3 (mode application) : \eO<final>
  defp read_ss3 do
    case read_char() do
      <<"A">> -> :up
      <<"B">> -> :down
      <<"C">> -> :right
      <<"D">> -> :left
      <<"H">> -> :home
      <<"F">> -> :end
      _ -> :ignore
    end
  end

  ## -- la boucle d'édition --

  defp edit_loop(state, prompt) do
    case read_key() do
      :eof ->
        :eof

      {:char, <<@cr>>} -> {:ok, Enum.join(state.buf)}
      {:char, <<@ctrl_c>>} -> :eof

      {:char, <<@ctrl_d>>} ->
        if state.buf == [] do
          :eof
        else
          state = delete_at_cursor(state)
          redraw(state, prompt)
          edit_loop(state, prompt)
        end

      # Ctrl+J : saut de ligne (Entrée = \r envoyé séparément ; en raw mode
      # Ctrl+J envoie \n, distinct). Insert \n dans le buffer.
      {:char, <<@ctrl_j>>} ->
        state = insert(state, "\n")
        redraw(state, prompt)
        edit_loop(state, prompt)

      {:char, <<@ctrl_w>>} ->
        state = delete_word_before(state)
        redraw(state, prompt)
        edit_loop(state, prompt)

      {:char, <<@backspace>>} ->
        state = backspace(state)
        redraw(state, prompt)
        edit_loop(state, prompt)

      {:char, <<@ctrl_h>>} ->
        state = backspace(state)
        redraw(state, prompt)
        edit_loop(state, prompt)

      :shift_enter ->
        state = insert(state, "\n")
        redraw(state, prompt)
        edit_loop(state, prompt)

      {:char, ch} ->
        state = insert(state, ch)
        redraw(state, prompt)
        edit_loop(state, prompt)

      :left ->
        state = %{state | cursor: max(0, state.cursor - 1)}
        redraw(state, prompt)
        edit_loop(state, prompt)

      :right ->
        state = %{state | cursor: min(length(state.buf), state.cursor + 1)}
        redraw(state, prompt)
        edit_loop(state, prompt)

      :home ->
        state = %{state | cursor: 0}
        redraw(state, prompt)
        edit_loop(state, prompt)

      :end ->
        state = %{state | cursor: length(state.buf)}
        redraw(state, prompt)
        edit_loop(state, prompt)

      :delete ->
        state = delete_at_cursor(state)
        redraw(state, prompt)
        edit_loop(state, prompt)

      :up ->
        state = history_up(state)
        redraw(state, prompt)
        edit_loop(state, prompt)

      :down ->
        state = history_down(state)
        redraw(state, prompt)
        edit_loop(state, prompt)

      :ignore ->
        edit_loop(state, prompt)
    end
  end

  ## -- édition du buffer --

  defp insert(state, ch), do: %{state | buf: List.insert_at(state.buf, state.cursor, ch), cursor: state.cursor + 1}

  defp backspace(state) do
    if state.cursor > 0 do
      %{state | buf: List.delete_at(state.buf, state.cursor - 1), cursor: state.cursor - 1}
    else
      state
    end
  end

  defp delete_at_cursor(state) do
    if state.cursor < length(state.buf) do
      %{state | buf: List.delete_at(state.buf, state.cursor)}
    else
      state
    end
  end

  # Ctrl+W (readline) : efface du curseur jusqu'au début du mot précédent.
  # Comportement : on saute d'abord les espaces, puis les caractères du mot.
  defp delete_word_before(state) do
    buf = state.buf
    i = state.cursor
    i = skip_whitespace_back(buf, i)
    i = skip_word_back(buf, i)
    delete_range(buf, i, state.cursor)
    |> then(&%{state | buf: &1, cursor: i})
  end

  defp skip_whitespace_back(buf, i) when i > 0 do
    if elem_at(buf, i - 1) in [" ", "\t", "\n"], do: skip_whitespace_back(buf, i - 1), else: i
  end

  defp skip_whitespace_back(_buf, i), do: i

  defp skip_word_back(buf, i) when i > 0 do
    if elem_at(buf, i - 1) not in [" ", "\t", "\n"], do: skip_word_back(buf, i - 1), else: i
  end

  defp skip_word_back(_buf, i), do: i

  defp elem_at(list, idx), do: Enum.at(list, idx)

  defp delete_range(buf, from, to) do
    {left, rest} = Enum.split(buf, from)
    {_removed, right} = Enum.split(rest, to - from)
    left ++ right
  end

  # ↑ : recule dans l'historique ; le buffer courant devient le "futur".
  defp history_up(state) do
    case state.hist do
      [] ->
        state

      [prev | rest] ->
        %{state | buf: String.graphemes(prev), cursor: length(String.graphemes(prev)), hist: rest, future: [Enum.join(state.buf) | state.future]}
    end
  end

  # ↓ : avance dans l'historique (vers le buffer édité).
  defp history_down(state) do
    case state.future do
      [] ->
        state

      [fut | rest] ->
        %{state | buf: String.graphemes(fut), cursor: length(String.graphemes(fut)), hist: [Enum.join(state.buf) | state.hist], future: rest}
    end
  end

  ## -- rendu multi-ligne --

  # Re-rend la zone (remonte en haut, efface, re-imprime prompt + buffer avec
  # les \n, replace le curseur à sa position ligne/colonne).
  defp redraw(state, prompt) do
    full = prompt <> Enum.join(state.buf)
    total_lines = max(1, full |> String.split("\n") |> length())
    # remonter de (total_lines - 1) lignes puis effacer jusqu'en bas
    if total_lines > 1, do: IO.write("\e[#{total_lines - 1}A")
    IO.write("\e[J" <> full)

    # position du curseur : ligne = nb de \n dans (prompt + buffer avant curseur)
    before = prompt <> (state.buf |> Enum.take(state.cursor) |> Enum.join())
    {line, col} = cursor_pos(before)
    IO.write("\e[#{line};#{col}H")
    state
  end

  defp cursor_pos(before) do
    case String.split(before, "\n") do
      [head | _] = parts ->
        {length(parts), String.length(head) + 1}
      _ ->
        {1, 1}
    end
  end
end
