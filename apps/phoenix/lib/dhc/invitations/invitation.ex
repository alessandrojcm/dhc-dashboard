defmodule Dhc.Invitations.Invitation do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "invitations" do
    field :email, :string
    # ALE-162: a fresh Phoenix UUID minted at issue time. It is the
    # eventual `principals.id` / `member_profiles.id` / `user_profile`
    # `supabase_user_id` once acceptance materializes the record set. No
    # `auth.users` row backs it (the auth.users FK was dropped in the
    # ALE-162 migration); the FK to `principals.id` is added in M2/ALE-163.
    field :prospective_principal_id, Ecto.UUID
    field :waitlist_id, Ecto.UUID
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :created_by_principal_id, Ecto.UUID
    field :invitation_type, :string
    # Membership discount indicated at issue time. `standard` pays full
    # price; `coach` resolves the configured 100%-off coupon and `student`
    # the configured 20%-off monthly coupon at acceptance (see
    # `Dhc.Invitations.Pricing.tier_coupon_id/1`).
    field :pricing_tier, :string, default: "standard"
    field :metadata, :map

    # ALE-162: carried at issue time so acceptance can build the
    # `UserProfile` without a pre-existing row. The bulk-invite flow used to
    # create the UserProfile at issue; under ADR 0010 the UserProfile is
    # born at acceptance, so the invitation carries the invite data between
    # issue and acceptance. All nullable for pre-ALE-162 rows; production
    # cutover deletes pending invitations (ADR 0010), so no backfill.
    field :first_name, :string
    field :last_name, :string
    field :phone_number, :string
    field :date_of_birth, :date

    timestamps(inserted_at: :created_at, type: :utc_datetime)
  end

  @doc false
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :email,
      :waitlist_id,
      :status,
      :expires_at,
      :invitation_type,
      :pricing_tier,
      :metadata,
      :first_name,
      :last_name,
      :phone_number,
      :date_of_birth
    ])
    |> validate_required([
      :email,
      :prospective_principal_id,
      :status,
      :expires_at,
      :invitation_type,
      :first_name,
      :last_name,
      :phone_number,
      :date_of_birth
    ])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_inclusion(:status, ~w(pending accepted expired revoked))
    |> validate_inclusion(:pricing_tier, ~w(standard coach student))
    |> unique_constraint(:email, name: :invitations_email_pending_unique)
  end
end
