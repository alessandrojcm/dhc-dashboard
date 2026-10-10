defmodule Dhc.BeginnersWorkshops.IntakePayment do
  @moduledoc """
  Ecto schema for `beginners_workshop_intake_payments` (ALE-381; CONTEXT.md
  "Seat Hold"): one Stripe Checkout attempt for one Intake.

  An `open` row **is** the Seat Hold. It counts as a taken seat until Stripe
  says the Checkout Session ended, so our clock alone never frees a seat:
  `expires_at` only tells the reaper when to ask Stripe to expire the
  session. The fee is frozen in `amount_cents` when the hold is taken.

      open → paid | releasing | released | policy_failed
      releasing → released | paid

  `releasing` (a hold whose Intake closed while the person was in checkout)
  no longer counts as a taken seat. Status changes only through the
  boundary's transition table. The row is always found by its Checkout
  Session id; the session's metadata carries the row id for humans only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w(open paid releasing released policy_failed)

  schema "beginners_workshop_intake_payments" do
    field :workshop_id, :binary_id
    field :intake_id, :binary_id
    field :status, :string, default: "open"
    field :amount_cents, :integer
    field :currency, :string, default: "eur"
    field :expires_at, :utc_datetime_usec
    field :stripe_checkout_session_id, :string
    field :checkout_url, :string, redact: true
    field :stripe_payment_intent_id, :string
    field :amount_received_cents, :integer
    field :currency_received, :string
    field :paid_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :policy_failed_at, :utc_datetime_usec
    # The Checkout Session parameters frozen with the hold (with the amount,
    # currency and expiry above), so every create of its session sends the
    # same request under its idempotency key. The link token is rebuilt from
    # the Intake id and `checkout_link_generation`, never stored; the email
    # is cleared once the session is recorded or the hold released.
    field :checkout_link_generation, :integer
    field :checkout_email, :string, redact: true
    field :checkout_product_name, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Every payment row status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  A new Seat Hold: an `open` row with the fee, its expiry and the rest of
  the Checkout Session parameters frozen (link generation, email, product
  name).
  """
  @spec hold_changeset(map()) :: Ecto.Changeset.t()
  def hold_changeset(attrs) do
    required = [
      :workshop_id,
      :intake_id,
      :amount_cents,
      :expires_at,
      :checkout_link_generation,
      :checkout_email,
      :checkout_product_name
    ]

    %__MODULE__{}
    |> cast(attrs, required)
    |> put_change(:status, "open")
    |> put_change(:currency, "eur")
    |> validate_required(required)
    |> validate_number(:amount_cents, greater_than: 0)
  end

  @doc """
  Records the Checkout Session Stripe created for the row. Its session will
  never be created again, so the frozen email copy is dropped.
  """
  @spec session_changeset(t(), String.t(), String.t() | nil) :: Ecto.Changeset.t()
  def session_changeset(%__MODULE__{} = row, session_id, url) do
    row
    |> change(stripe_checkout_session_id: session_id, checkout_url: url, checkout_email: nil)
    |> validate_required([:stripe_checkout_session_id])
  end
end
