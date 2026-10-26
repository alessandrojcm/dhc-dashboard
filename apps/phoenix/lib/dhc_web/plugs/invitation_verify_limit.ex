defmodule DhcWeb.Plugs.InvitationVerifyLimit do
  @moduledoc """
  Rate-limits `POST /api/invitations/:id/verify` (security-audit run-1,
  lead 5).

  Verification is a public credential oracle: it answers whether the
  invitation id + email + date-of-birth triple is exactly right, and an
  over-limit request must never widen that answer. The plug shares
  `MagicLinkRateLimit`'s window machinery (the one web→Repo seam) and
  answers an over-limit request with the **same 422 problem body as wrong
  credentials** — non-enumerating, and slow enough to make the DOB space
  unassailable:

    * 5 attempts per invitation id per hour
    * 30 attempts per resolved client IP per hour (SvelteKit-server
      requests arrive with the member's own address through the trusted
      forwarding header, like the magic-link limiter)

  Responses are identical for limited/unknown/incorrect requests, so the
  limiter leaks nothing; a legitimate applicant who mistypes a date of
  birth can still retry a few times per hour.
  """

  @behaviour Plug

  alias DhcWeb.Plugs.ClientIp
  alias DhcWeb.Plugs.MagicLinkRateLimit

  @invitation_window_seconds 60 * 60
  @invitation_max_per_window 5
  @ip_window_seconds 60 * 60
  @ip_max_per_window 30

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case window_keys(conn) do
      {:ok, invitation_key} ->
        ip_key = "invitation_verify:ip:#{ClientIp.to_string(conn)}"

        with :ok <- check_window(ip_key, @ip_window_seconds, @ip_max_per_window, :ip),
             :ok <-
               check_window(
                 invitation_key,
                 @invitation_window_seconds,
                 @invitation_max_per_window,
                 :invitation
               ) do
          conn
        else
          {:error, {:limited, limit}} ->
            :telemetry.execute(
              [:dhc, :invitations, :verify, :rate_limited],
              %{limit: limit},
              %{}
            )

            refused(conn)
        end

      # No invitation id (or an unusable path param) — the controller's own
      # verification-required handling answers this; do not count it.
      _no_invitation ->
        conn
    end
  end

  defp window_keys(conn) do
    case conn.path_params do
      %{"id" => id} when is_binary(id) and id != "" ->
        {:ok, "invitation_verify:invitation:#{id}"}

      _ ->
        {:error, :no_invitation}
    end
  end

  defp check_window(key, window_seconds, max, limit) do
    count =
      MagicLinkRateLimit.bump_window(key, MagicLinkRateLimit.window_start_for(window_seconds))

    if count <= max, do: :ok, else: {:error, {:limited, limit}}
  end

  # Identical to a failed verification (`InvitationsHTTP`): a limited
  # request must not be distinguishable from wrong credentials.
  defp refused(conn) do
    conn
    |> DhcWeb.Problem.send_reason(:invalid_credentials, DhcWeb.InvitationsHTTP.problem_config())
  end
end
