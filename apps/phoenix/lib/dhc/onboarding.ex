defmodule Dhc.Onboarding do
  @moduledoc """
  Owns the conversion side of Onboarding: Invitation issue and credential
  verification.

  The browser-facing acceptance session lives behind an opaque handle in
  `Dhc.Onboarding.Acceptance`; controllers and workers call that module
  directly. This module keeps the Invitation-level operations that are not
  part of one browser's session.
  """

  import Ecto.Query

  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo

  @doc """
  Verifies public Invitation credentials without issuing bearer material.

  Once a protected acceptance session has started for the Invitation, this
  compatibility check refuses so the credentials cannot be probed outside the
  session.
  """
  @spec verify_credentials(String.t(), String.t(), String.t() | Date.t()) ::
          :ok | {:error, :invalid_credentials}
  def verify_credentials(invitation_id, email, date_of_birth) do
    if protected_acceptance_started?(invitation_id),
      do: {:error, :invalid_credentials},
      else: Invitations.verify_credentials(invitation_id, email, date_of_birth)
  end

  @spec issue_invitations([map() | String.t()], map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def issue_invitations(invites, user) when is_list(invites) and invites != [] do
    Oban.insert(BulkInviteWorker.new(%{"invites" => invites, "user" => user}))
  end

  defp protected_acceptance_started?(invitation_id) do
    case Ecto.UUID.cast(invitation_id) do
      {:ok, invitation_id} ->
        Repo.exists?(
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.invitation_id == ^invitation_id
          )
        )

      :error ->
        false
    end
  end
end
