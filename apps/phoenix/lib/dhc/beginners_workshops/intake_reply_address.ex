defmodule Dhc.BeginnersWorkshops.IntakeReplyAddress do
  @moduledoc """
  One opaque inbound address binding for an Intake Email (ALE-407).

  The address token is a credential and is never stored; `token_hash` is its
  SHA-256 digest. The binding is deleted with the Waitlist entry.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dhc.BeginnersWorkshops.Intake
  alias Dhc.Waitlist.WaitlistEntry

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          waitlist_entry: WaitlistEntry.t() | Ecto.Association.NotLoaded.t(),
          intake: Intake.t() | nil | Ecto.Association.NotLoaded.t()
        }

  schema "beginners_workshop_intake_reply_addresses" do
    belongs_to :waitlist_entry, WaitlistEntry, foreign_key: :waitlist_id
    belongs_to :intake, Intake
    field :email_type, :string
    field :token_hash, :binary

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = binding) do
    binding
    |> change(Map.take(binding, [:waitlist_id, :intake_id, :email_type, :token_hash]))
    |> validate_required([:waitlist_id, :email_type, :token_hash])
    |> validate_length(:email_type, max: 80)
    |> validate_change(:token_hash, fn :token_hash, hash ->
      if is_binary(hash) and byte_size(hash) == 32,
        do: [],
        else: [token_hash: "must be a SHA-256 digest"]
    end)
    |> foreign_key_constraint(:waitlist_id)
    |> foreign_key_constraint(:intake_id)
    |> unique_constraint(:token_hash,
      name: "beginners_workshop_intake_reply_addresses_token_hash_index"
    )
  end
end
