defmodule DhcWeb.InvitationsController do
  use DhcWeb, :controller

  require Logger

  alias Dhc.{Invitations, Onboarding}

  action_fallback DhcWeb.InvitationsHTTP

  @doc """
  GET /invitations
  """
  def list(conn, params) do
    case Invitations.list(params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.InvitationsJSON)
        |> render(:list, result: result)

      error ->
        DhcWeb.Problem.list_error(error)
    end
  end

  @doc """
  GET /invitations/:id
  """
  def show(conn, %{"id" => id}) do
    with {:ok, invitation} <- Invitations.public_lookup(id) do
      conn
      |> put_view(json: DhcWeb.InvitationsJSON)
      |> render(:public_show, invitation: invitation)
    end
  end

  @doc """
  POST /invitations/:id/verify
  """
  def verify(conn, %{"id" => id, "email" => email, "dateOfBirth" => date_of_birth}) do
    with :ok <- Onboarding.verify_credentials(id, email, date_of_birth) do
      conn
      |> put_view(json: DhcWeb.InvitationsJSON)
      |> render(:verify)
    end
  end

  def verify(_conn, _params), do: {:error, :verification_required}

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

        {:error, :enqueue_failed}
    end
  end

  def create(_conn, _params), do: {:error, :invites_required}

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

  def resend(_conn, _params), do: {:error, :emails_required}

  @doc """
  DELETE /invitations
  """
  def delete(conn, %{"invitationIds" => invitation_ids}) do
    with :ok <- Invitations.delete_many(invitation_ids) do
      send_resp(conn, :no_content, "")
    end
  end

  def delete(_conn, _params), do: {:error, :invalid_invitation_ids}
end
