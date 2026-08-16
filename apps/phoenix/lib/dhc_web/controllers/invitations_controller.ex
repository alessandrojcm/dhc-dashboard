defmodule DhcWeb.InvitationsController do
  use DhcWeb, :controller

  require Logger

  alias Dhc.{Invitations, Onboarding}

  @doc """
  GET /invitations
  """
  def list(conn, params) do
    case Invitations.list(params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:list, result: result)

      {:error, :bad_cursor} ->
        bad_request(conn, "Invalid or mismatched cursor")

      {:error, _reason} ->
        bad_request(conn, "Invalid invitations query")
    end
  end

  @doc """
  GET /invitations/:id
  """
  def show(conn, %{"id" => id}) do
    case Invitations.public_lookup(id) do
      {:ok, invitation} ->
        conn
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:public_show, invitation: invitation)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invitation not found")
    end
  end

  @doc """
  GET /invitations/:id/pricing
  """
  def pricing(conn, %{"id" => id} = params) do
    case Onboarding.pricing(id, Map.get(params, "code")) do
      {:ok, pricing} ->
        conn
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:pricing, pricing: pricing)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invitation not found")

      {:error, :invalid_promotion_code} ->
        conn
        |> put_status(:bad_request)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invalid or inactive promotion code")

      {:error, :forever_amount_coupon} ->
        conn
        |> put_status(:bad_request)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error,
          detail: "Forever coupons can only be percentage-based, not amount-based"
        )

      {:error, :membership_not_required} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invitation does not require Membership pricing")

      {:error, reason} ->
        Logger.error("[invitations] Failed to calculate invitation pricing",
          invitation_id: id,
          reason: inspect(reason)
        )

        conn
        |> put_status(:internal_server_error)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Failed to get pricing details")
    end
  end

  @doc """
  POST /invitations/:id/verify
  """
  def verify(conn, %{"id" => id, "email" => email, "dateOfBirth" => date_of_birth}) do
    case Onboarding.verify_credentials(id, email, date_of_birth) do
      :ok ->
        conn
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:verify)

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invalid invitation credentials")
    end
  end

  def verify(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InvitationsJSON)
    |> render(:error, detail: "email and dateOfBirth are required")
  end

  @doc """
  POST /invitations/:id/accept
  """
  def accept(
        conn,
        %{
          "id" => id,
          "nextOfKinName" => next_of_kin_name,
          "nextOfKinPhone" => next_of_kin_phone
        } = params
      ) do
    with [continuation_id] <- get_req_header(conn, "x-onboarding-continuation"),
         :ok <- validate_acceptance_payload(next_of_kin_name, next_of_kin_phone),
         {:ok, result} <-
           Onboarding.accept(
             id,
             continuation_id,
             next_of_kin_name,
             next_of_kin_phone,
             payment_attrs(conn, params)
           ) do
      conn
      |> put_view(json: DhcWeb.InvitationsJSON)
      |> render(:accept, result: result)
    else
      {:error, :invalid_payload} ->
        invalid_acceptance_payload(conn)

      {:error, :invalid_token} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invalid verification token")

      {:error, :discord_verification_required} ->
        conn
        |> put_status(:conflict)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Discord verification is required before payment")

      {:error, :acceptance_in_progress} ->
        conn
        |> put_status(:conflict)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invitation acceptance is already in progress")

      missing_or_ambiguous_header when is_list(missing_or_ambiguous_header) ->
        conn
        |> put_status(:conflict)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Discord verification is required before payment")

      {:error, :invalid_invitation} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invitation cannot be accepted")

      {:error, {:payment_failed, reason}} ->
        Logger.warning("[invitations] Stripe payment failed during invitation acceptance",
          invitation_id: id,
          reason: inspect(reason)
        )

        conn
        |> put_status(:payment_required)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Payment could not be completed")

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invitation acceptance failed")
    end
  end

  def accept(conn, _params) do
    invalid_acceptance_payload(conn)
  end

  defp validate_acceptance_payload(next_of_kin_name, next_of_kin_phone) do
    if present_string?(next_of_kin_name) and present_string?(next_of_kin_phone) do
      :ok
    else
      {:error, :invalid_payload}
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp payment_attrs(conn, params) do
    mandate_context = Map.get(params, "mandateContext", %{})

    %{
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
  end

  defp client_ip(conn) do
    conn.remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp invalid_acceptance_payload(conn) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InvitationsJSON)
    |> render(:error, detail: "acceptance payload is invalid")
  end

  @doc """
  POST /invitations
  """
  def create(conn, %{"invites" => [_ | _] = invites}) do
    current_session = conn.assigns.current_session

    user = %{
      "id" => current_session.principal.id,
      "email" => current_session.principal.email
    }

    case Onboarding.issue_invitations(invites, user) do
      {:ok, job} ->
        Logger.info("[invitations] Enqueued invitation job",
          oban_job_id: job.id,
          created_by: current_session.principal.id,
          invite_count: length(invites)
        )

        conn
        |> put_status(:accepted)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:show, invitation: %{queued: true, job_id: job.id})

      {:error, changeset} ->
        Logger.error("[invitations] Failed to enqueue invitation job",
          errors: inspect(changeset.errors)
        )

        conn
        |> put_status(:bad_request)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Failed to enqueue invitation job")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InvitationsJSON)
    |> render(:error, detail: "invites must be a non-empty list")
  end

  @doc """
  POST /invitations/resend
  """
  def resend(conn, %{"emails" => [_ | _] = emails}) do
    with {:ok, result} <- Invitations.resend_invitation_emails(emails) do
      conn
      |> put_status(:accepted)
      |> put_view(json: DhcWeb.InvitationsJSON)
      |> render(:resend, invitation_resend: result)
    end
  end

  def resend(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InvitationsJSON)
    |> render(:error, detail: "emails must be a non-empty list")
  end

  @doc """
  DELETE /invitations
  """
  def delete(conn, %{"invitationIds" => invitation_ids}) do
    case Invitations.delete_many(invitation_ids) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :invalid_invitation_ids} -> invalid_invitation_ids(conn)
    end
  end

  def delete(conn, _params), do: invalid_invitation_ids(conn)

  defp invalid_invitation_ids(conn) do
    bad_request(conn, "invitationIds must be a non-empty list of UUIDs")
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end
end
