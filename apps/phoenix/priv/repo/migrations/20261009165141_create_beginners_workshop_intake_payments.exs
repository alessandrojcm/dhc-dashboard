defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopIntakePayments do
  @moduledoc """
  ALE-381 (ADR 0029): Intake payment rows — the Seat Holds — and how an
  Intake was paid.

  Additive. A payment row is one Stripe Checkout attempt for one Intake. An
  `open` row is a Seat Hold: it counts as a taken seat until Stripe says the
  Checkout Session has ended (`paid`, or `released` on expiry). The fee is
  frozen on the row when the hold is taken. A partial unique index allows one
  `open` row per Intake, and the row is always found by its Checkout Session
  id (unique).
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshop_intakes) do
      add :paid_via, :text
      add :paid_at, :utc_datetime_usec
    end

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_paid_via_check,
        check: "paid_via IS NULL OR paid_via IN ('stripe', 'carried_fee')"
      )
    )

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_paid_check,
        check: "state <> 'paid' OR (paid_via IS NOT NULL AND paid_at IS NOT NULL)"
      )
    )

    create table(:beginners_workshop_intake_payments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workshop_id, references(:beginners_workshops, type: :binary_id, on_delete: :restrict),
        null: false

      add :intake_id,
          references(:beginners_workshop_intakes, type: :binary_id, on_delete: :restrict),
          null: false

      add :status, :text, null: false, default: "open"
      # The fee frozen when the hold was taken.
      add :amount_cents, :integer, null: false
      add :currency, :text, null: false, default: "eur"
      # When the Seat Hold's 30 minutes run out; the reaper then asks Stripe
      # to expire the session. The seat stays taken until Stripe answers.
      add :expires_at, :utc_datetime_usec, null: false
      add :stripe_checkout_session_id, :text
      add :checkout_url, :text
      add :stripe_payment_intent_id, :text
      # What Stripe reported when a completion was checked (kept on a
      # policy failure for the refund).
      add :amount_received_cents, :integer
      add :currency_received, :text
      add :paid_at, :utc_datetime_usec
      add :released_at, :utc_datetime_usec
      add :policy_failed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(index(:beginners_workshop_intake_payments, [:intake_id]))

    create(
      index(:beginners_workshop_intake_payments, [:workshop_id],
        where: "status = 'open'",
        name: :beginners_workshop_intake_payments_open_by_workshop_index
      )
    )

    create(
      index(:beginners_workshop_intake_payments, [:expires_at],
        where: "status = 'open'",
        name: :beginners_workshop_intake_payments_open_expiry_index
      )
    )

    # One live Seat Hold per Intake.
    create(
      unique_index(:beginners_workshop_intake_payments, [:intake_id],
        where: "status = 'open'",
        name: :beginners_workshop_intake_payments_one_open_index
      )
    )

    create(
      unique_index(:beginners_workshop_intake_payments, [:stripe_checkout_session_id],
        name: :beginners_workshop_intake_payments_session_index
      )
    )

    create(
      constraint(
        :beginners_workshop_intake_payments,
        :beginners_workshop_intake_payments_status_check,
        check: "status IN ('open', 'paid', 'releasing', 'released', 'policy_failed')"
      )
    )

    create(
      constraint(
        :beginners_workshop_intake_payments,
        :beginners_workshop_intake_payments_amount_check,
        check: "amount_cents > 0"
      )
    )

    create(
      constraint(
        :beginners_workshop_intake_payments,
        :beginners_workshop_intake_payments_currency_check,
        check: "currency = 'eur'"
      )
    )
  end
end
