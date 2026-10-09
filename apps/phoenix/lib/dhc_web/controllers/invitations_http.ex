defmodule DhcWeb.InvitationsHTTP do
  @moduledoc """
  The problem fallback for the Invitations HTTP slice. Invitation Acceptance's
  safe-view responses are not rendered here (ADR 0024).
  """

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "Invitation not found"},
      invalid_query: {400, "Invalid invitations query"},
      verification_required: {400, "email and dateOfBirth are required"},
      invites_required: {400, "invites must be a non-empty list"},
      invite_objects_required:
        {400, "invites must be invite objects; Waitlist entry ids are not accepted"},
      enqueue_failed: {400, "Failed to enqueue invitation job"},
      emails_required: {400, "emails must be a non-empty list"},
      invalid_invitation_ids: {400, "invitationIds must be a non-empty list of UUIDs"},
      invalid_credentials: {422, "Invalid invitation credentials"}
    }
end
