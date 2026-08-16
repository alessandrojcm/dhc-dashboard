defmodule DhcWeb.OnboardingController do
  use DhcWeb, :controller

  alias Dhc.Onboarding

  @acceptance_cookie "_dhc_onboarding_acceptance"
  @acceptance_max_age 15 * 60

  def verify_invitation_acceptance(conn, %{
        "invitationId" => id,
        "email" => email,
        "dateOfBirth" => date_of_birth
      }) do
    protected_continuation_id = acceptance_id_from_cookie(conn)

    case Onboarding.start_acceptance(id, email, date_of_birth, protected_continuation_id) do
      {:ok, %{continuation_id: continuation_id, view: state}} ->
        conn
        |> put_resp_cookie(
          @acceptance_cookie,
          continuation_id,
          acceptance_cookie_opts()
        )
        |> render_state(state)

      {:error, :missing_browser_proof} ->
        restart_verification(conn, :conflict)

      {:error, _} ->
        restart_verification(conn, :unprocessable_entity)
    end
  end

  def verify_invitation_acceptance(conn, _params),
    do: restart_verification(conn, :unprocessable_entity)

  def start_acceptance(conn, %{
        "invitationId" => id,
        "email" => email,
        "dateOfBirth" => date_of_birth
      }) do
    case Onboarding.start_acceptance(id, email, date_of_birth, continuation_id(conn)) do
      {:ok, %{continuation_id: continuation_id, view: state}} ->
        conn
        |> put_resp_header("x-onboarding-continuation", continuation_id)
        |> render_legacy_state(state)

      {:error, :missing_browser_proof} ->
        legacy_restart_verification(conn, :conflict)

      {:error, _reason} ->
        legacy_restart_verification(conn, :unprocessable_entity)
    end
  end

  def start_acceptance(conn, _params),
    do: legacy_restart_verification(conn, :unprocessable_entity)

  def show_acceptance(conn, _params) do
    with continuation_id when is_binary(continuation_id) <- continuation_id(conn),
         {:ok, state} <- Onboarding.acceptance_state(continuation_id) do
      render_legacy_state(conn, state)
    else
      _ -> legacy_restart_verification(conn)
    end
  end

  def show_invitation_acceptance(conn, _params) do
    with continuation_id when is_binary(continuation_id) <- acceptance_id_from_cookie(conn),
         {:ok, state} <- Onboarding.acceptance_state(continuation_id) do
      render_state(conn, state)
    else
      _ -> restart_verification(conn, :conflict)
    end
  end

  def start_discord(conn, _params) do
    with continuation_id when is_binary(continuation_id) <- continuation_id(conn),
         {:ok, %{state: state}} when state in ["awaiting_oauth", "awaitingDiscord"] <-
           Onboarding.acceptance_state(continuation_id) do
      DhcWeb.AuthSessionController.request_acceptance_discord(conn, continuation_id)
    else
      _ -> restart_verification(conn, :conflict)
    end
  end

  def cancel_discord(conn, _params) do
    with continuation_id when is_binary(continuation_id) <- continuation_id(conn),
         {:ok, state} <- Onboarding.cancel_discord(continuation_id) do
      render_legacy_state(conn, state)
    else
      _ -> restart_verification(conn, :conflict)
    end
  end

  def continue_acceptance(conn, _params) do
    with continuation_id when is_binary(continuation_id) <- continuation_id(conn),
         {:ok, state} <- Onboarding.continue_acceptance(continuation_id) do
      render_state(conn, state)
    else
      _ -> current_or_restart(conn)
    end
  end

  def submit_payment(
        conn,
        %{
          "nextOfKinName" => next_of_kin_name,
          "nextOfKinPhone" => next_of_kin_phone,
          "stripeConfirmationToken" => confirmation_token
        } = params
      ) do
    continuation_id = continuation_id(conn)
    mandate_context = Map.get(params, "mandateContext", %{})

    attrs = %{
      next_of_kin_name: next_of_kin_name,
      next_of_kin_phone: next_of_kin_phone,
      confirmation_token: confirmation_token,
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

    case Onboarding.submit_payment(continuation_id, attrs) do
      {:ok, state} ->
        render_state(conn, state)

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
    with continuation_id when is_binary(continuation_id) <- continuation_id(conn),
         {:ok, state} <- Onboarding.retry_acceptance(continuation_id) do
      render_state(conn, state)
    else
      _ -> current_or_restart(conn)
    end
  end

  defp render_state(conn, state) do
    data =
      %{state: state.state}
      |> maybe_put(:expiresAt, state[:expires_at] && DateTime.to_iso8601(state.expires_at))
      |> maybe_put(:invitationEmail, state[:invitation_email])
      |> maybe_put(:discord, state[:discord])
      |> maybe_put(:payment, state[:payment])
      |> maybe_put(:discordVerified, state[:discord_verified])
      |> maybe_put(:retryAllowed, state[:retry_allowed])

    json(conn, %{data: data})
  end

  defp render_legacy_state(conn, state) do
    state =
      Map.update(state, :state, "restartVerification", fn
        "awaiting_oauth" -> "awaitingDiscord"
        "restart_verification" -> "restartVerification"
        value -> value
      end)

    render_state(conn, state)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp restart_verification(conn, status) do
    conn
    |> put_status(status)
    |> json(%{data: %{state: "restart_verification"}})
  end

  defp legacy_restart_verification(conn, status \\ :conflict) do
    conn
    |> put_status(status)
    |> json(%{data: %{state: "restartVerification"}})
  end

  defp acceptance_id_from_cookie(conn) do
    conn
    |> fetch_cookies(signed: [@acceptance_cookie])
    |> then(& &1.cookies[@acceptance_cookie])
  end

  defp continuation_id(conn) do
    acceptance_id_from_cookie(conn) ||
      get_req_header(conn, "x-onboarding-continuation") |> List.first()
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
    with continuation_id when is_binary(continuation_id) <- continuation_id(conn),
         {:ok, state} <- Onboarding.acceptance_state(continuation_id) do
      conn |> put_status(status) |> render_state(state)
    else
      _ -> restart_verification(conn, :conflict)
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
