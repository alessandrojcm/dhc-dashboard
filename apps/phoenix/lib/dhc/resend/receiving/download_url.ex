defmodule Dhc.Resend.Receiving.DownloadUrl do
  @moduledoc """
  Which download URLs the server is willing to fetch (security-audit run-1,
  lead 8).

  `download/1` fetches a URL **as a credential** (the signed URL is the only
  authorization), and Resend minted it — but the URL travels through a
  webhook payload, a queued job's read and our own attachment list, so
  anything short of "this is a Resend host" is a blind SSRF primitive: a
  public DNS name can resolve to loopback, RFC 1918, link-local or Fly's
  `fdaa::/16` 6PN. Resend's own documentation puts both downloads on Resend
  hosts:

    * attachments: `inbound-cdn.resend.com`
    * the raw `.eml`: a signed CloudFront URL on `*.resend.com`

  Suffixes match only on a label boundary, so `evilresend.com` and
  `resend.com.attacker.example` are rejected. The URL must be https with no
  userinfo; a single trailing root dot on the host is tolerated. Redirects
  are not followed (`Dhc.Resend.Receiving.download/1` pins them), so the
  first hop's host is the only host.

  Deployment still owes its own egress policy for private/loopback/
  link-local destinations (owner-validated, audit run-1).
  """

  @exact_hosts ~w(inbound-cdn.resend.com)
  @suffixes ~w(.resend.com)

  # Deployment escape hatch: exact hosts or `.suffix` strings appended at
  # runtime if Resend ever mints downloads on another host. Tests add their
  # stub hosts here (`config/test.exs`).
  def allowed_host?(host) when is_binary(host) do
    case normalize(host) do
      {:ok, hostname} ->
        extra = Application.get_env(:dhc, :resend_download_allow_hosts, [])

        host in @exact_hosts or hostname in @exact_hosts or
          Enum.any?(@suffixes, &String.ends_with?(hostname, &1)) or
          Enum.any?(extra, &(hostname == &1 or String.ends_with?(hostname, &1)))

      :error ->
        false
    end
  end

  def allowed_host?(_host), do: false

  # One trailing root label only; `".resend.com"`, `host..` and `""` are
  # malformed.
  defp normalize(host) do
    lowered = host |> String.downcase() |> String.replace_suffix(".", "")

    if lowered == "" or String.starts_with?(lowered, ".") or String.contains?(lowered, "..") or
         String.ends_with?(lowered, "."),
       do: :error,
       else: {:ok, lowered}
  end
end
