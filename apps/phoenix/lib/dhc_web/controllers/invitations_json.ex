defmodule DhcWeb.InvitationsJSON do
  @moduledoc false

  def render("list.json", %{result: result}) do
    %{
      data: %{
        invitations: Enum.map(result.invitations, &invitation/1),
        totalCount: result.total_count,
        limit: result.limit,
        nextCursor: result.next_cursor,
        previousCursor: result.previous_cursor
      }
    }
  end

  def render("show.json", %{invitation: invitation}) do
    %{data: render_invitation(invitation)}
  end

  def render("resend.json", %{invitation_resend: invitation_resend}) do
    %{data: render_invitation_resend(invitation_resend)}
  end

  def render("error.json", %{detail: detail}) do
    %{errors: %{detail: detail}}
  end

  defp render_invitation(invitation) do
    %{
      job_id: invitation.job_id,
      queued: invitation.queued
    }
  end

  defp render_invitation_resend(invitation_resend) do
    %{
      failed: invitation_resend.failed,
      succeeded: invitation_resend.succeeded
    }
  end

  # Only the fields the UI consumes — see Invitation DTO in the OpenAPI spec.
  defp invitation(invitation) do
    %{
      id: invitation.id,
      email: invitation.email,
      status: invitation.status,
      expiresAt: invitation.expires_at,
      createdAt: invitation.created_at
    }
  end
end
