defmodule Dhc.BeginnersWorkshops.IntakeRefund do
  @moduledoc """
  Ecto schema for `beginners_workshop_intake_refunds` (ALE-382; ALE-374
  "Refund"): giving back the full amount one Intake payment row took.

      pending → processing | completed | failed
      processing → completed | failed

  A Stripe refund (`method: "stripe"`) is created `pending` and submitted
  by the refund worker under its idempotency key
  `beginners-intake-refund:<id>`; Stripe may answer the create terminally,
  so `pending` can go straight to `completed` or `failed`. `completed` and
  `failed` are terminal: later Stripe events are ignored.

  A manual refund (`method: "manual"`, `record_manual_refund`) is written
  `completed` from the start. A failed refund stays as history: Retry and
  Record manual refund each insert a new row whose `follows_refund_id` is
  the failed one.

  ALE-389: a refund may refund a Carried Fee (`carried_fee_id`). It is
  still the full amount originally paid, against the original payment: a
  deferral's fee keeps `payment_id` (its Intake payment row); an imported
  fee linked to its Stripe PaymentIntent has no payment row, and no
  workshop or Intake when the person had none to attach it to. Otherwise
  `workshop_id` / `intake_id` name the Intake the refund is about. `requested_by_principal_id` is nil for an automatic
  refund (one the system requested). Status changes only through the
  boundary's transition table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w(pending processing completed failed)
  @methods ~w(stripe manual)

  # Refunds the system owes without anyone asking (stories 57 and 58).
  @automatic_reasons ~w(policy_failed paid_after_close)

  schema "beginners_workshop_intake_refunds" do
    field :workshop_id, :binary_id
    field :intake_id, :binary_id
    field :payment_id, :binary_id
    field :carried_fee_id, :binary_id
    field :follows_refund_id, :binary_id
    field :status, :string, default: "pending"
    field :method, :string, default: "stripe"
    field :reason, :string
    field :amount_cents, :integer
    field :currency, :string, default: "eur"
    field :idempotency_key, :string
    field :stripe_payment_intent_id, :string
    field :stripe_refund_id, :string
    field :provider_status, :string
    field :last_error, :string
    field :note, :string
    field :requested_by_principal_id, :binary_id
    field :requested_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Every refund status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The reasons the system refunds automatically."
  @spec automatic_reasons() :: [String.t()]
  def automatic_reasons, do: @automatic_reasons

  @doc "Whether a refund was owed automatically rather than requested by someone."
  @spec automatic?(t()) :: boolean()
  def automatic?(%__MODULE__{reason: reason}), do: reason in @automatic_reasons

  @doc "The idempotency key of a refund row's Stripe refund."
  @spec idempotency_key(binary()) :: String.t()
  def idempotency_key(id) when is_binary(id), do: "beginners-intake-refund:#{id}"

  @doc """
  A new refund of a payment row. `attrs` carry the workshop, Intake,
  payment, reason, amount, currency, the PaymentIntent, the request time and,
  for a follow-up, the refund it follows and who asked.
  """
  @spec request_changeset(map()) :: Ecto.Changeset.t()
  def request_changeset(attrs) do
    id = Ecto.UUID.generate()

    %__MODULE__{id: id}
    |> cast(attrs, [
      :workshop_id,
      :intake_id,
      :payment_id,
      :carried_fee_id,
      :follows_refund_id,
      :reason,
      :amount_cents,
      :currency,
      :stripe_payment_intent_id,
      :requested_by_principal_id,
      :requested_at
    ])
    |> put_change(:status, "pending")
    |> put_change(:method, "stripe")
    |> put_change(:idempotency_key, idempotency_key(id))
    |> validate_required([:reason, :amount_cents, :currency, :requested_at])
    |> validate_source()
    |> validate_number(:amount_cents, greater_than: 0)
  end

  # A payment's refund names its workshop, Intake and payment; a Carried
  # Fee's names the fee, and a workshop and Intake only together.
  defp validate_source(changeset) do
    cond do
      is_nil(get_field(changeset, :carried_fee_id)) ->
        validate_required(changeset, [:workshop_id, :intake_id, :payment_id])

      is_nil(get_field(changeset, :intake_id)) != is_nil(get_field(changeset, :workshop_id)) ->
        add_error(changeset, :intake_id, "must name its workshop")

      true ->
        changeset
    end
  end

  @doc "A manual refund recorded after `failed` refund: written `completed`."
  @spec manual_changeset(t(), binary(), String.t() | nil, DateTime.t()) :: Ecto.Changeset.t()
  def manual_changeset(%__MODULE__{} = failed, principal_id, note, at) do
    id = Ecto.UUID.generate()

    %__MODULE__{id: id}
    |> change(
      workshop_id: failed.workshop_id,
      intake_id: failed.intake_id,
      payment_id: failed.payment_id,
      carried_fee_id: failed.carried_fee_id,
      follows_refund_id: failed.id,
      status: "completed",
      method: "manual",
      reason: failed.reason,
      amount_cents: failed.amount_cents,
      currency: failed.currency,
      idempotency_key: idempotency_key(id),
      requested_by_principal_id: principal_id,
      note: note,
      requested_at: at,
      completed_at: at
    )
    |> validate_length(:note, max: 500)
    |> validate_inclusion(:method, @methods)
  end
end
