defmodule Dhc.Invitations.Invitation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "invitations" do
    field :email, :string
    # ALE-162: a fresh Phoenix UUID minted at issue time. It is the
    # eventual `principals.id` / `member_profiles.id` / `user_profile`
    # `supabase_user_id` once acceptance materializes the record set. No
    # `auth.users` row backs it (the auth.users FK was dropped in the
    # ALE-162 migration); the FK to `principals.id` is added in M2/ALE-163.
    field :user_id, Ecto.UUID
    field :waitlist_id, Ecto.UUID
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :created_by, Ecto.UUID
    field :invitation_type, :string
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

    # ALE-162: lazily set by the pricing endpoint on first preview, so
    # acceptance can reuse the same Stripe customer instead of minting a
    # new one when the invitee already opened the pricing page.
    field :stripe_customer_id, :string

    timestamps(inserted_at: :created_at, type: :utc_datetime)
  end
end
