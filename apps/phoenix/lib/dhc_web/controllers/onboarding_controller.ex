defmodule DhcWeb.OnboardingController do
  use DhcWeb, :controller

  alias Dhc.Onboarding.Acceptance

  @acceptance_cookie "_dhc_onboarding_acceptance"
  @acceptance_max_age 15 * 60

  def verify_invitation_acceptance(conn, %{
        "invitationId" => id,
        "email" => email,
        "dateOfBirth" => date_of_birth
      }) do
    case Acceptance.open(id, email, date_of_birth, acceptance_handle(conn)) do
      {:ok, handle, view} ->
        conn
        |> put_resp_cookie(@acceptance_cookie, handle, acceptance_cookie_opts())
        |> render_view(view)

      {:error, :missing_browser_proof} ->
        restart_verification(conn, :conflict)

      {:error, _reason} ->
        restart_verification(conn, :unprocessable_entity)
    end
  end

  def verify_invitation_acceptance(conn, _params),
    do: restart_verification(conn, :unprocessable_entity)

  def show_invitation_acceptance(conn, _params) do
    case Acceptance.view(acceptance_handle(conn)) do
      {:ok, view} -> render_view(conn, view)
      {:error, _reason} -> restart_verification(conn, :conflict)
    end
  end

  def start_discord(conn, _params) do
    handle = acceptance_handle(conn)

    case Acceptance.view(handle) do
      {:ok, %{state: "awaiting_oauth"}} ->
        DhcWeb.AuthSessionController.request_acceptance_discord(conn, handle)

      _other ->
        restart_verification(conn, :conflict)
    end
  end

  def cancel_discord(conn, _params) do
    case Acceptance.cancel_discord(acceptance_handle(conn)) do
      {:ok, view} -> render_view(conn, view)
      {:error, _reason} -> restart_verification(conn, :conflict)
    end
  end

  def continue_acceptance(conn, _params) do
    case Acceptance.consume_proof(acceptance_handle(conn)) do
      {:ok, view} -> render_view(conn, view)
      {:error, _reason} -> current_or_restart(conn)
    end
  end

  def submit_payment(
        conn,
        %{
          "nextOfKinName" => next_of_kin_name,
          "nextOfKinPhone" => next_of_kin_phone
        } = params
      ) do
    mandate_context = Map.get(params, "mandateContext", %{})

    input = %{
      next_of_kin_name: next_of_kin_name,
      next_of_kin_phone: next_of_kin_phone,
      confirmation_token: Map.get(params, "stripeConfirmationToken"),
      coupon_code: Map.get(params, "couponCode"),
      mandate_context: %{
        ip_address: Map.get(mandate_context, "ipAddress", client_ip(conn)),
        user_agent:
          Map.get(
            mandate_context,
            "userAgent",
            get_req_header(conn, "user-agent") |> List.first()
          )
      }
    }

    case Acceptance.submit_payment(acceptance_handle(conn), input) do
      {:ok, view} ->
        render_view(conn, view)

      {:error, {:payment_failed, _reason}} ->
        current_or_restart(conn, :payment_required)

      {:error, {:provider_unavailable, _reason}} ->
        provider_unavailable(conn)

      {:error, :invalid_acceptance_details} ->
        error_detail(conn, :unprocessable_entity, "Invalid payment details")

      {:error, :invalid_continuation} ->
        current_or_restart(conn)

      {:error, _reason} ->
        error_detail(conn, :internal_server_error, "Invitation acceptance could not be finalized")
    end
  end

  def submit_payment(conn, _params),
    do: error_detail(conn, :unprocessable_entity, "Invalid payment details")

  def retry_acceptance(conn, _params) do
    case Acceptance.retry(acceptance_handle(conn)) do
      {:ok, view} -> render_view(conn, view)
      {:error, _reason} -> current_or_restart(conn)
    end
  end

  defp render_view(conn, view) do
    data =
      %{state: view.state}
      |> maybe_put(:expiresAt, view[:expires_at] && DateTime.to_iso8601(view.expires_at))
      |> maybe_put(:invitationEmail, view[:invitation_email])
      |> maybe_put(:discord, view[:discord])
      |> maybe_put(:discordVerified, view[:discord_verified])
      |> maybe_put(:retryAllowed, view[:retry_allowed])
      |> maybe_put(:complimentary, view[:complimentary])

    json(conn, %{data: data})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp restart_verification(conn, status) do
    conn
    |> put_status(status)
    |> json(%{data: %{state: "restart_verification"}})
  end

  defp acceptance_handle(conn) do
    conn
    |> fetch_cookies(signed: [@acceptance_cookie])
    |> then(& &1.cookies[@acceptance_cookie])
  end

  defp acceptance_cookie_opts do
    [
      sign: true,
      http_only: true,
      secure: Application.get_env(:dhc, :auth_session_secure, false),
      same_site: Application.get_env(:dhc, :auth_session_same_site, "Lax"),
      path: "/api/onboarding/invitation-acceptance",
      max_age: @acceptance_max_age
    ]
  end

  defp current_or_restart(conn, status \\ :conflict) do
    case Acceptance.view(acceptance_handle(conn)) do
      {:ok, view} -> conn |> put_status(status) |> render_view(view)
      {:error, _reason} -> restart_verification(conn, :conflict)
    end
  end

  defp provider_unavailable(conn) do
    error_detail(
      conn,
      :service_unavailable,
      "Payment progression is temporarily unavailable; recovery is scheduled"
    )
  end

  defp error_detail(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: %{detail: detail}})
  end

  defp client_ip(conn) do
    conn.remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
end
