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
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          {status, completed_at} =
            case provider_status do
              "succeeded" -> {"completed", refund.completed_at || now}
              "failed" -> {"failed", nil}
              _ -> {"processing", nil}
            end

          refund
          |> Ecto.Changeset.change(
            status: status,
            provider_status: provider_status,
            completed_at: completed_at,
            last_error: if(status == "failed", do: "Stripe refund failed", else: nil)
          )
          |> Repo.update!()

          if status == "completed" and is_binary(refund.payment_attempt_id) do
            from(pa in PaymentAttempt, where: pa.id == ^refund.payment_attempt_id)
            |> Repo.update_all(set: [status: "refunded", concluded_at: now, updated_at: now])
          end
      end
    end)

    :ok
  end

  def apply_provider_update(_object), do: {:error, :invalid_refund_object}
end
