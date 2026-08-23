defmodule Dhc.Repo.Migrations.RemoveStripeCustomerIdFromInvitations do
  use Ecto.Migration

  @moduledoc """
  ADR 0013 moved Stripe work out of the invitation issue flow, leaving
  `invitations.stripe_customer_id` as a write-only historical field: new
  pricing never writes it and the acceptance workflow now carries the
  customer id on `invitation_acceptance_attempts` (see
  `Dhc.Onboarding.InvitationAcceptanceAttempt`). Production cutover deleted
  pending invitations (ADR 0010), so no pre-ADR-0013 rows remain to resume.
  """

  def change do
    alter table(:invitations, primary_key: false) do
      remove :stripe_customer_id
    end
  end
end
