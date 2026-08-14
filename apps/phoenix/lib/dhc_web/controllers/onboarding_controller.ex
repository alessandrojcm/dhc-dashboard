defmodule DhcWeb.OnboardingController do
  use DhcWeb, :controller

  alias Dhc.Onboarding

  def start_acceptance(conn, %{
        "invitationId" => id,
        "email" => email,
        "dateOfBirth" => date_of_birth
      }) do
    protected_continuation_id =
      case get_req_header(conn, "x-onboarding-continuation") do
        [continuation_id] -> continuation_id
        _ -> nil
      end

    case Onboarding.start_acceptance(id, email, date_of_birth, protected_continuation_id) do
      {:ok, state} ->
        conn
        |> put_resp_header("x-onboarding-continuation", state.continuation_id)
        |> render_state(state)

      {:error, _} ->
        restart_verification(conn)
    end
  end

  def start_acceptance(conn, _params), do: restart_verification(conn)

  # These opaque references are supplied only by the SvelteKit protected
  # browser-session cookie. The public API never accepts an Invitation id here.
  def show_acceptance(conn, _params) do
    with [continuation_id] <- get_req_header(conn, "x-onboarding-continuation"),
         {:ok, state} <- Onboarding.acceptance_state(continuation_id) do
      render_state(conn, state)
    else
      _ -> restart_verification(conn)
    end
  end

  def start_discord(conn, _params) do
    with [continuation_id] <- get_req_header(conn, "x-onboarding-continuation"),
         {:ok, %{state: "awaitingDiscord"}} <- Onboarding.acceptance_state(continuation_id) do
      DhcWeb.AuthSessionController.request_acceptance_discord(conn, continuation_id)
    else
      _ -> restart_verification(conn)
    end
  end

  def cancel_discord(conn, _params) do
    with [continuation_id] <- get_req_header(conn, "x-onboarding-continuation"),
         {:ok, state} <- Onboarding.cancel_discord(continuation_id) do
      render_state(conn, state)
    else
      _ -> restart_verification(conn)
    end
  end

  def continue_acceptance(
        conn,
        %{
          "nextOfKinName" => next_of_kin_name,
          "nextOfKinPhone" => next_of_kin_phone,
          "stripeConfirmationToken" => confirmation_token
        } = params
      ) do
    continuation_id = get_req_header(conn, "x-onboarding-continuation") |> List.first()
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

    case Onboarding.continue_acceptance(continuation_id, attrs) do
      {:ok, state} -> render_state(conn, state)
      {:error, {:payment_failed, _reason}} -> current_or_restart(conn, :payment_required)
      {:error, _reason} -> current_or_restart(conn)
    end
  end

  def continue_acceptance(conn, _params), do: current_or_restart(conn)

  def retry_acceptance(conn, _params) do
    with [continuation_id] <- get_req_header(conn, "x-onboarding-continuation"),
         {:ok, state} <- Onboarding.retry_acceptance(continuation_id) do
      render_state(conn, state)
    else
      _ -> current_or_restart(conn)
    end
  end

  defp render_state(conn, state) do
    data =
      %{state: state.state}
      |> maybe_put(:invitationEmail, state[:invitation_email])
      |> maybe_put(:discord, state[:discord])
      |> maybe_put(:payment, state[:payment])

    json(conn, %{data: data})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp restart_verification(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{data: %{state: "restartVerification"}})
  end

  defp current_or_restart(conn, status \\ :conflict) do
    with [continuation_id] <- get_req_header(conn, "x-onboarding-continuation"),
         {:ok, state} <- Onboarding.acceptance_state(continuation_id) do
      conn |> put_status(status) |> render_state(state)
    else
      _ -> restart_verification(conn)
    end
  end

  defp client_ip(conn) do
    conn.remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
end
