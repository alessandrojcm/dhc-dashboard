defmodule DhcWeb.InvitationsController do
  use DhcWeb, :controller

  require Logger

  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker

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
  POST /invitations/:id/verify
  """
  def verify(conn, %{"id" => id, "email" => email, "dateOfBirth" => date_of_birth}) do
    case Invitations.verify_credentials(id, email, date_of_birth) do
      {:ok, token} ->
        conn
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:verify, verification_token: token)

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
  def accept(conn, %{
        "id" => id,
        "verificationToken" => token,
        "nextOfKinName" => next_of_kin_name,
        "nextOfKinPhone" => next_of_kin_phone,
        "stripeConfirmationToken" => _stripe_confirmation_token
      }) do
    with :ok <- validate_acceptance_payload(next_of_kin_name, next_of_kin_phone),
         {:ok, result} <- Invitations.accept(id, token, next_of_kin_name, next_of_kin_phone) do
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

      {:error, :invalid_invitation} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:error, detail: "Invitation cannot be accepted")

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

  defp invalid_acceptance_payload(conn) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.InvitationsJSON)
    |> render(:error, detail: "acceptance payload is invalid")
  end

  @doc """
  POST /invitations
  """
  def create(conn, %{"invites" => invites}) when is_list(invites) and length(invites) > 0 do
    current_user = conn.assigns.current_user

    args = %{
      "invites" => invites,
      "user" => %{
        "id" => current_user.sub,
        "email" => current_user[:email]
      }
    }

    case Oban.insert(BulkInviteWorker.new(args)) do
      {:ok, job} ->
        Logger.info("[invitations] Enqueued invitation job",
          oban_job_id: job.id,
          created_by: current_user.sub,
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
  def resend(conn, %{"emails" => emails}) when is_list(emails) and length(emails) > 0 do
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

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end
end
