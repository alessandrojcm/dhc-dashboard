defmodule Dhc.Workshops.Refund do
  @moduledoc """
  Read-only Ecto schema for the `club_activity_refunds` table.

  Maps the **persistence** vocabulary for Workshop refunds. Each refund is tied
  to a single registration (`registration_id` → `club_activity_registrations`),
  and the participant identity is reached through that registration. The
  public/domain name exposed by `Dhc.Workshops` is "refund"; keep this schema
  internal.

  `status` is the Postgres `refund_status` enum (`pending`, `processing`,
  `completed`, `failed`, `cancelled`), declared as `:string` (Postgres
  implicitly casts enum ↔ text). `requested_by` / `processed_by` reference
  `auth.users(id)` (nullable).
  """

  use Ecto.Schema

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.Workshops.PaymentAttempt

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "club_activity_refunds" do
    field :registration_id, :binary_id
    field :payment_attempt_id, :binary_id

    field :refund_amount, :integer
    field :refund_reason, :string
    field :status, :string, default: "pending"

    field :stripe_refund_id, :string
    field :stripe_payment_intent_id, :string
    field :idempotency_key, :string
    field :provider_status, :string
    field :last_error, :string

    field :requested_at, :utc_datetime
    field :processed_at, :utc_datetime
    field :completed_at, :utc_datetime

    # `requested_by` / `processed_by` reference `auth.users(id)` (nullable).
    field :requested_by, :binary_id
    field :processed_by, :binary_id

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  @doc false
  def apply_provider_update(%{"id" => stripe_refund_id, "status" => provider_status}) do
    Repo.transaction(fn ->
      case Repo.one(
             from(r in __MODULE__,
               where: r.stripe_refund_id == ^stripe_refund_id,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          :ok

        %__MODULE__{status: status} when status in ["completed", "failed", "cancelled"] ->
          :ok

        refund ->
          apply_refund_status(refund, provider_status)
      end
    end)

    :ok
  end

  def apply_provider_update(_object), do: {:error, :invalid_refund_object}

  defp apply_refund_status(refund, provider_status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {status, completed_at} = local_status(provider_status, refund.completed_at, now)

    refund
    |> Ecto.Changeset.change(
      status: status,
      provider_status: provider_status,
      completed_at: completed_at,
      last_error: if(status == "failed", do: "Stripe refund failed", else: nil)
    )
    |> Repo.update!()

    maybe_mark_payment_attempt_refunded(refund.payment_attempt_id, status, now)
  end

  defp local_status("succeeded", completed_at, now), do: {"completed", completed_at || now}
  defp local_status("failed", _completed_at, _now), do: {"failed", nil}
  defp local_status(_provider_status, _completed_at, _now), do: {"processing", nil}

  defp maybe_mark_payment_attempt_refunded(payment_attempt_id, "completed", now)
       when is_binary(payment_attempt_id) do
    from(pa in PaymentAttempt, where: pa.id == ^payment_attempt_id)
    |> Repo.update_all(set: [status: "refunded", concluded_at: now, updated_at: now])
  end

  defp maybe_mark_payment_attempt_refunded(_payment_attempt_id, _status, _now), do: :ok
end
