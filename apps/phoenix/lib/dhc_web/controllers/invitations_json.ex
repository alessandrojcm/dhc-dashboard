defmodule DhcWeb.InvitationsJSON do
  @moduledoc false

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
end
