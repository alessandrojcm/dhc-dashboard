defmodule Dhc.Notifications.WebPush.Endpoint do
  @moduledoc """
  Which push-subscription endpoints the server is willing to POST to.

  The endpoint is member-supplied, and every notification makes the server
  send a request to it, so anything short of "this is a real browser push
  service" is a blind SSRF primitive: a public DNS name can resolve to
  loopback, RFC 1918, link-local or Fly's `fdaa::/16` 6PN. Instead of guessing
  at local-looking names, the host must be one of the push services browsers
  actually mint endpoints on:

    * Chrome / Chromium-based browsers (FCM): `fcm.googleapis.com`, plus the
      legacy GCM `android.googleapis.com` and `jmt17.google.com`
    * Firefox (Mozilla autopush): `*.push.services.mozilla.com`
      (`updates.push.services.mozilla.com`)
    * Edge (WNS): `*.notify.windows.com`
    * Safari (Apple Web Push): `*.push.apple.com` (`web.push.apple.com`)

  Sources: W3C Push API; Mozilla autopush docs; Apple "Sending web push
  notifications in web apps and browsers"; pushpad/known-push-services.

  Suffixes match only on a label boundary, so `evilfcm.googleapis.com` and
  `fcm.googleapis.com.attacker.example` are rejected. The URL must be https
  with no userinfo; a single trailing root dot on the host is tolerated.

  The check runs both when a subscription is stored and again before each
  send, so rows stored before the allowlist existed cannot be pushed to.
  """

  @exact_hosts ~w(fcm.googleapis.com android.googleapis.com jmt17.google.com)
  @suffixes ~w(.push.services.mozilla.com .notify.windows.com .push.apple.com)

  @doc "`true` when `endpoint` is an https URL on an allowlisted push service."
  @spec allowed?(term()) :: boolean()
  def allowed?(endpoint), do: errors(endpoint) == []

  @doc "Changeset-style errors for `endpoint`; `[]` when it is allowed."
  @spec errors(term()) :: [{:endpoint, String.t()}]
  def errors(endpoint) when is_binary(endpoint) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        host_errors(host)

      _ ->
        [endpoint: "must be an https URL"]
    end
  end

  def errors(_endpoint), do: [endpoint: "must be an https URL"]

  defp host_errors(host) do
    case normalize(host) do
      {:ok, hostname} ->
        if push_service?(hostname), do: [], else: [endpoint: "must be a known push service"]

      :error ->
        [endpoint: "must be an https URL"]
    end
  end

  # One trailing root label only; `"."` and `host..` are malformed.
  defp normalize(host) do
    lowered = host |> String.downcase() |> String.replace_suffix(".", "")

    if lowered == "" or String.ends_with?(lowered, "."), do: :error, else: {:ok, lowered}
  end

  defp push_service?(host) do
    host in @exact_hosts or Enum.any?(@suffixes, &String.ends_with?(host, &1))
  end
end
