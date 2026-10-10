defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopIntakeRefunds do
  @moduledoc """
  ALE-382 (ADR 0029): Intake refunds — the full amount originally paid,
  against one Intake payment row.

  Additive. A Stripe refund runs `pending → processing → completed | failed`
  under the idempotency key `beginners-intake-refund:<id>`; a manual refund
  (the coordinator paid the person back outside Stripe) is recorded
  `completed` with `method = 'manual'`. A failed refund is kept as history:
  Retry and Record manual refund each write a new row that `follows` it. A
  partial unique index allows one refund per payment that has not failed,
  so a payment is never refunded twice.
  """

  use Ecto.Migration

  def change do
    create table(:beginners_workshop_intake_refunds, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workshop_id, references(:beginners_workshops, type: :binary_id, on_delete: :restrict),
        null: false

      add :intake_id,
          references(:beginners_workshop_intakes, type: :binary_id, on_delete: :restrict),
          null: false

      add :payment_id,
          references(:beginners_workshop_intake_payments,
            type: :binary_id,
            on_delete: :restrict
          ),
          null: false

      add :follows_refund_id,
          references(:beginners_workshop_intake_refunds, type: :binary_id, on_delete: :restrict)

      add :status, :text, null: false, default: "pending"
      add :method, :text, null: false, default: "stripe"
      # Why the refund was owed (`policy_failed`, `paid_after_close`, …).
      add :reason, :text, null: false
      add :amount_cents, :integer, null: false
      add :currency, :text, null: false, default: "eur"
      add :idempotency_key, :text, null: false
      add :stripe_payment_intent_id, :text
      add :stripe_refund_id, :text
      add :provider_status, :text
      add :last_error, :text
      add :note, :text

      # Null for an automatic refund (requested by the system).
      add :requested_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :nilify_all)

      add :requested_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(index(:beginners_workshop_intake_refunds, [:workshop_id]))
    create(index(:beginners_workshop_intake_refunds, [:intake_id]))
    create(index(:beginners_workshop_intake_refunds, [:payment_id]))

    create(
      unique_index(:beginners_workshop_intake_refunds, [:follows_refund_id],
        name: :beginners_workshop_intake_refunds_follows_index
      )
    )

    create(
      index(:beginners_workshop_intake_refunds, [:status],
        where: "status IN ('pending', 'processing')",
        name: :beginners_workshop_intake_refunds_unresolved_index
      )
    )

    # A payment is refunded at most once: only failed refunds may repeat.
    create(
      unique_index(:beginners_workshop_intake_refunds, [:payment_id],
        where: "status <> 'failed'",
        name: :beginners_workshop_intake_refunds_one_live_index
      )
    )

    create(
      unique_index(:beginners_workshop_intake_refunds, [:idempotency_key],
        name: :beginners_workshop_intake_refunds_idempotency_key_index
      )
    )

    create(
      unique_index(:beginners_workshop_intake_refunds, [:stripe_refund_id],
        name: :beginners_workshop_intake_refunds_stripe_refund_index
      )
    )

    create(
      constraint(
        :beginners_workshop_intake_refunds,
        :beginners_workshop_intake_refunds_status_check,
        check: "status IN ('pending', 'processing', 'completed', 'failed')"
      )
    )

    create(
      constraint(
        :beginners_workshop_intake_refunds,
        :beginners_workshop_intake_refunds_method_check,
        check: "method IN ('stripe', 'manual') AND (method = 'stripe' OR status = 'completed')"
      )
    )

    create(
      constraint(
        :beginners_workshop_intake_refunds,
        :beginners_workshop_intake_refunds_amount_check,
        check: "amount_cents > 0"
      )
    )
  end
end
