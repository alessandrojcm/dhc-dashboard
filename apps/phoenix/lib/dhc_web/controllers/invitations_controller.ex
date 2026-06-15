defmodule DhcWeb.InvitationsController do
  use DhcWeb, :controller

  require Logger

  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker

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
end
