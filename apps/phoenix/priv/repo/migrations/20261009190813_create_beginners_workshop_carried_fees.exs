defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopCarriedFees do
  @moduledoc """
  ALE-388 (ADR 0029, CONTEXT.md "Carried Fee"): a prepaid seat that never
  expires, owned by the person (their Waitlist entry).

  Additive. A Carried Fee is created `held` when a Stripe-paid Intake is
  deferred (`origin = 'deferral'`, pointing at that Intake's payment row,
  which is never edited) or by the one-time Waitlist spreadsheet import
  (`origin = 'import'`, an imported record of a payment this system did not
  make: the Paid cell's raw text, and a nullable Stripe payment reference and
  amount that staff fill in later, ALE-389). Its status changes only through
  the boundary's transition table:

      held → applied | refunded | forfeited
      applied → held | spent | refunded | forfeited

  `applied_intake_id` is the Intake it paid (set while `applied`, kept once
  spent or forfeited). A person holds at most one live (`held` or `applied`)
  Carried Fee (partial unique index); an ended one stays for reporting. On
  the person's hard delete the row is kept with no link to them.

  Intakes record the Carried Fee that paid them (`paid_via = 'carried_fee'`).
  """

  use Ecto.Migration

  def change do
    create table(:beginners_workshop_carried_fees, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :waitlist_id, references(:waitlist, type: :binary_id, on_delete: :nilify_all)
      add :status, :text, null: false, default: "held"
      add :origin, :text, null: false

      # The original payment: a deferred Intake's payment row.
      add :payment_id,
          references(:beginners_workshop_intake_payments,
            type: :binary_id,
            on_delete: :restrict
          )

      # What was originally paid (for an imported fee, once staff link it).
      add :amount_cents, :integer
      add :currency, :text, null: false, default: "eur"
      # An imported fee: the Paid cell as written, and the Stripe payment
      # staff link it to later (ALE-389).
      add :imported_paid_text, :text
      add :stripe_payment_intent_id, :text

      add :applied_intake_id,
          references(:beginners_workshop_intakes, type: :binary_id, on_delete: :restrict)

      add :status_changed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      unique_index(:beginners_workshop_carried_fees, [:waitlist_id],
        where: "status IN ('held', 'applied')",
        name: :beginners_workshop_carried_fees_one_live_per_person_index
      )
    )

    create(index(:beginners_workshop_carried_fees, [:waitlist_id]))

    create(
      unique_index(:beginners_workshop_carried_fees, [:payment_id],
        name: :beginners_workshop_carried_fees_payment_index
      )
    )

    create(index(:beginners_workshop_carried_fees, [:applied_intake_id]))

    create(
      constraint(:beginners_workshop_carried_fees, :beginners_workshop_carried_fees_status_check,
        check: "status IN ('held', 'applied', 'spent', 'refunded', 'forfeited')"
      )
    )

    create(
      constraint(:beginners_workshop_carried_fees, :beginners_workshop_carried_fees_origin_check,
        check:
          "(origin = 'deferral' AND payment_id IS NOT NULL) OR " <>
            "(origin = 'import' AND payment_id IS NULL AND imported_paid_text IS NOT NULL)"
      )
    )

    create(
      constraint(:beginners_workshop_carried_fees, :beginners_workshop_carried_fees_applied_check,
        check: "status <> 'applied' OR applied_intake_id IS NOT NULL"
      )
    )

    create(
      constraint(:beginners_workshop_carried_fees, :beginners_workshop_carried_fees_amount_check,
        check: "amount_cents IS NULL OR amount_cents > 0"
      )
    )

    alter table(:beginners_workshop_intakes) do
      add :carried_fee_id,
          references(:beginners_workshop_carried_fees, type: :binary_id, on_delete: :restrict)
    end

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_carried_fee_check,
        check: "(paid_via IS NOT DISTINCT FROM 'carried_fee') = (carried_fee_id IS NOT NULL)"
      )
    )
  end
end
