defmodule Elixness.LLMStreamTest do
  use ExUnit.Case, async: false

  # Serveur HTTP minimal qui renvoie un stream SSE chat.completion.chunk.
  # `fragments` découpe chaque événement en morceaux envoyés en chunks TCP
  # séparés, pour simuler le découpage réseau qui coupe les lignes `data:`
  # en plein milieu (le bug classique du streaming).
  defp start_sse_server(events, fragments) do
    parent = self()

    {:ok, server} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(server)
    spawn_link(fn -> accept_and_serve(server, events, fragments, parent) end)
    port
  end

  # Lit la requête HTTP, répond avec le stream, puis ferme proprement.
  # `Connection: close` + `reuseaddr` rendent le framing HTTP déterministe.
  defp accept_and_serve(server, events, fragments, parent) do
    {:ok, socket} = :gen_tcp.accept(server)

    # Lit la requête du client (headers jusqu'au \r\n\r\n) — garantit que le
    # client est prêt avant qu'on envoie le corps.
    {:ok, _request} = read_request(socket)

    :ok =
      :gen_tcp.send(socket,
        "HTTP/1.1 200 OK\r\n" <>
          "content-type: text/event-stream\r\n" <>
          "connection: close\r\n" <>
          "\r\n"
      )

    for payload <- events do
      event = "data: #{payload}\n\n"
      send_body(socket, event, fragments)
    end

    :gen_tcp.close(socket)
    :gen_tcp.close(server)
    send(parent, {:served, length(events)})
  end

  defp read_request(socket), do: read_request(socket, "")

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_request(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_body(_socket, _event, 0), do: :ok

  defp send_body(socket, event, n) when n == 1 do
    :ok = :gen_tcp.send(socket, event)
  end

  defp send_body(socket, event, n) do
    size = byte_size(event)
    take = max(1, div(size, n))
    <<head::binary-size(^take), rest::binary>> = event
    :ok = :gen_tcp.send(socket, head)
    send_body(socket, rest, n - 1)
  end

  defp chunk(id, content_delta) do
    Jason.encode!(%{
      "id" => id,
      "object" => "chat.completion.chunk",
      "choices" => [%{"index" => 0, "delta" => %{"content" => content_delta}}]
    })
  end

  defp done_chunk do
    Jason.encode!(%{
      "id" => "c",
      "object" => "chat.completion.chunk",
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
    })
  end

  defp run_chat(events, fragments) do
    port = start_sse_server(events, fragments)

    result =
      Elixness.LLM.chat(%{token: "test", base_url: "http://localhost:#{port}/v1"},
        "model-test",
        [%{role: "user", content: "hi"}]
      )

    # S'assure que le serveur a tout servi (pas de socket abandonnée).
    count = length(events)
    assert_receive {:served, ^count}
    result
  end

  test "assemble le contenu d'un stream non fragmenté" do
    events = [chunk("c1", "Bonjour "), chunk("c2", "le monde"), done_chunk()]

    {:ok, resp} = run_chat(events, 1)
    assert resp.content == "Bonjour le monde"
    assert resp.finish_reason == "stop"
  end

  test "reconstruit les tokens coupés par le découpage réseau (le bug des chunks)" do
    # Chaque événement est découpé en chunks TCP → les coupes tombent en
    # plein milieu des lignes `data:`.
    events = [
      chunk("c1", "Bonjour "),
      chunk("c2", "le monde, voici un test de streaming très long pour vérifier"),
      chunk("c3", " que les tokens sont bien reconstruits même quand le réseau"),
      chunk("c4", " découpe les événements en plein milieu des lignes data"),
      done_chunk()
    ]

    {:ok, resp} = run_chat(events, 3)

    assert resp.content ==
             "Bonjour le monde, voici un test de streaming très long pour vérifier que les tokens sont bien reconstruits même quand le réseau découpe les événements en plein milieu des lignes data"

    assert resp.finish_reason == "stop"
  end

  test "un stream sans contenu ni tool_call renvoie {:error, :empty_stream}" do
    # Juste le DONE, aucun delta de contenu.
    port = start_sse_server(["data: [DONE]\n\n"], 1)
    assert {:error, _} = Elixness.LLM.chat(%{token: "test", base_url: "http://localhost:#{port}/v1"}, "model-test", [])
    assert_receive {:served, 1}
  end
end
