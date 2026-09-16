defmodule Dhc.Notifications.WebPush.HttpSender do
  @moduledoc """
  ALE-299: default `Dhc.Notifications.WebPush.Sender` — RFC 8291 `aes128gcm`
  encryption and RFC 8292 VAPID via `web_push_ex`, transported with Req.

  `web_push_ex` deliberately stops at "here is the request": it returns the
  endpoint, headers and encrypted body and never performs I/O, which keeps
  Req the single sanctioned HTTP client (`.reach.exs`) and lets tests route
  the POST through a Req `plug:` instead of a network.

  The VAPID private key is read by `web_push_ex` from
  `config :web_push_ex, :vapid` at call time and is never logged or returned.
  """

  @behaviour Dhc.Notifications.WebPush.Sender

  alias Dhc.Notifications.PushSubscription

  # How long the push service may hold the message for an offline device.
  # Notifications are the durable record; a day-old push for a row the member
  # has since read in the dashboard is noise, so this stays short of the
  # library's 12h default only in spirit — one day covers an overnight phone.
  @ttl_seconds 24 * 60 * 60

  @impl true
  def push(%PushSubscription{} = subscription, payload) when is_map(payload) do
    {url, headers, body} = build(subscription, payload)

    [url: url, body: body, headers: headers]
    |> Keyword.merge(req_options())
    |> Req.new()
    |> Req.post()
    |> classify()
  end

  @doc false
  # The wire request without the hop: `{url, headers, encrypted_body}`. Public
  # only so the test can assert the RFC 8188/8292 header shape — Req's test
  # adapter strips a `Content-Encoding` it cannot decompress before a plug
  # sees it.
  @spec build(PushSubscription.t(), map()) :: {String.t(), %{String.t() => String.t()}, binary()}
  def build(%PushSubscription{} = subscription, payload) do
    request =
      WebPushEx.request(
        %WebPushEx.Subscription{
          endpoint: URI.parse(subscription.endpoint),
          keys: %{p256dh: subscription.p256dh, auth: subscription.auth}
        },
        Jason.encode!(payload)
      )

    headers = Map.merge(request.headers, %{"TTL" => Integer.to_string(@ttl_seconds)})
    {URI.to_string(request.endpoint), headers, request.body}
  end

  defp classify({:ok, %Req.Response{status: status}}) when status in 200..202, do: :ok

  defp classify({:ok, %Req.Response{status: status}}) when status in [404, 410],
    do: {:error, :gone}

  defp classify({:ok, %Req.Response{status: status}}), do: {:error, {:push_service, status}}
  defp classify({:error, reason}), do: {:error, {:transport, reason}}

  # Test seam: `config :dhc, :web_push_req_options, plug: fn conn -> ... end`
  # replaces the network hop with an in-process Plug. Empty in every real
  # environment.
  #
  # Redirects are never followed: the endpoint is member-supplied, and a
  # redirect is the one way a validated public host could point the POST at
  # something internal.
  defp req_options do
    Application.get_env(:dhc, :web_push_req_options, [])
    |> Keyword.put_new(:retry, false)
    |> Keyword.put(:redirect, false)
  end
end
