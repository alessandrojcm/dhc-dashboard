defmodule Dhc.BeginnersWorkshops.CarriedFee do
  @moduledoc """
  Ecto schema for `beginners_workshop_carried_fees` (ALE-388; CONTEXT.md
  "Carried Fee"): a prepaid seat that never expires and covers one seat at a
  later Beginners' Workshop whatever its fee. Owned by the person (their
  Waitlist entry, nulled on hard delete so the row stays for reporting).

  It points at the original payment, which is never edited:

    * `origin: "deferral"` — a Stripe-paid Intake was deferred; `payment_id`
      is its payment row and `amount_cents` what that row took;
    * `origin: "import"` — the one-time Waitlist spreadsheet import; the
      original payment is an imported record, not a Stripe payment this
      system made: `imported_paid_text` is the Paid cell as written, and the
      nullable `stripe_payment_intent_id` / `amount_cents` are filled in when
      staff link it to its Stripe payment (ALE-389).

  Status changes only through the boundary's transition table:

      held → applied | refunded | forfeited
      applied → held | spent | refunded | forfeited

  `applied_intake_id` is the Intake it paid by confirmation. A person holds
  at most one live (`held` or `applied`) Carried Fee (partial unique index).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w(held applied spent refunded forfeited)
  @live ~w(held applied)

  schema "beginners_workshop_carried_fees" do
    field :waitlist_id, :binary_id
    field :status, :string, default: "held"
    field :origin, :string
    field :payment_id, :binary_id
    field :amount_cents, :integer
    field :currency, :string, default: "eur"
    field :imported_paid_text, :string
    field :stripe_payment_intent_id, :string
    field :applied_intake_id, :binary_id
    field :status_changed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Every Carried Fee status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The live statuses: a person holds at most one Carried Fee in them."
  @spec live_statuses() :: [String.t()]
  def live_statuses, do: @live

  @doc "A `held` Carried Fee from a deferred Stripe-paid Intake's payment row."
  @spec deferral_changeset(map()) :: Ecto.Changeset.t()
  def deferral_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:waitlist_id, :payment_id, :amount_cents, :currency, :status_changed_at])
    |> put_change(:status, "held")
    |> put_change(:origin, "deferral")
    |> validate_required([:waitlist_id, :payment_id, :status_changed_at])
  end

  @doc "A `held` Carried Fee from the Waitlist spreadsheet import's Paid cell."
  @spec import_changeset(map()) :: Ecto.Changeset.t()
  def import_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:waitlist_id, :imported_paid_text, :status_changed_at])
    |> put_change(:status, "held")
    |> put_change(:origin, "import")
    |> validate_required([:waitlist_id, :imported_paid_text, :status_changed_at])
  end

  @doc "Applied to (or, with `nil`, taken back from) the Intake it pays."
  @spec status_changeset(t(), String.t(), binary() | nil, DateTime.t()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = fee, status, applied_intake_id, at) do
    change(fee, status: status, applied_intake_id: applied_intake_id, status_changed_at: at)
  end
end
