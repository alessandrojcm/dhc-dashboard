defmodule Dhc.Notifications.WebPush.HttpSenderTest do
  @moduledoc """
  ALE-299: the real encrypt-and-POST hop, with the network replaced by a Req
  `plug:`. Proves the wire shape a push service expects (RFC 8291 `aes128gcm`
  body, RFC 8292 `vapid` authorization built from the configured key pair) and
  that the service's answers are classified the way the context relies on.
  """

  use ExUnit.Case, async: false

  alias Dhc.Notifications.PushSubscription
  alias Dhc.Notifications.WebPush.HttpSender

  setup do
    original = Application.get_env(:dhc, :web_push_req_options)
    on_exit(fn -> restore(original) end)
    :ok
  end

  test "builds an aes128gcm-encrypted body with VAPID authorization and a TTL" do
    {url, headers, body} =
      HttpSender.build(subscription("https://push.example.org/send/abc"), %{body: "Hi"})

    assert url == "https://push.example.org/send/abc"
    assert headers["Content-Encoding"] == "aes128gcm"
    assert headers["Content-Type"] == "application/octet-stream"
    assert headers["TTL"] == "86400"
    assert headers["Content-Length"] == Integer.to_string(byte_size(body))

    assert String.starts_with?(headers["Authorization"], "vapid t=")

    assert headers["Authorization"] =~
             ", k=" <> Application.get_env(:web_push_ex, :vapid)[:public_key]

    # RFC 8188 header: 16-byte salt, 4-byte record size, key id length 65 (an
    # uncompressed P-256 point), then ciphertext + 16-byte GCM tag.
    assert <<_salt::binary-16, 4096::unsigned-big-32, 65, _as_public::binary-65,
             ciphertext::binary>> = body

    assert byte_size(ciphertext) > 16
    refute body =~ "Hi"
  end

  test "posts the built request to the subscription endpoint and treats 201 as accepted" do
    test_pid = self()

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:pushed, conn, body})
      Plug.Conn.send_resp(conn, 201, "")
    end)

    assert :ok = HttpSender.push(subscription("https://push.example.org/send/abc"), %{body: "Hi"})

    assert_received {:pushed, conn, body}
    assert conn.method == "POST"
    assert conn.host == "push.example.org"
    assert conn.request_path == "/send/abc"
    assert Plug.Conn.get_req_header(conn, "ttl") == ["86400"]
    assert [<<"vapid t=", _::binary>>] = Plug.Conn.get_req_header(conn, "authorization")
    assert byte_size(body) > 86
  end

  test "404 and 410 are :gone; other statuses and transport errors are ordinary failures" do
    for status <- [404, 410] do
      stub(fn conn -> Plug.Conn.send_resp(conn, status, "") end)
      assert {:error, :gone} = HttpSender.push(subscription("https://push.example.org/x"), %{})
    end

    for status <- [400, 413, 429, 500, 503] do
      stub(fn conn -> Plug.Conn.send_resp(conn, status, "") end)

      assert {:error, {:push_service, ^status}} =
               HttpSender.push(subscription("https://push.example.org/x"), %{})
    end

    stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, {:transport, %Req.TransportError{reason: :econnrefused}}} =
             HttpSender.push(subscription("https://push.example.org/x"), %{})
  end

  defp stub(plug), do: Application.put_env(:dhc, :web_push_req_options, plug: plug)

  defp restore(nil), do: Application.delete_env(:dhc, :web_push_req_options)
  defp restore(original), do: Application.put_env(:dhc, :web_push_req_options, original)

  defp subscription(endpoint) do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %PushSubscription{
      id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      endpoint: endpoint,
      p256dh: Base.url_encode64(public, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end
end
