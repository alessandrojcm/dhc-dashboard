defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopCarriedFeeRefunds do
  @moduledoc """
  ALE-389 (ADR 0029, CONTEXT.md "Carried Fee"): Carried Fee refunds and
  forfeits.

  Additive. A refund row may now refund a Carried Fee (`carried_fee_id`),
  always the full amount originally paid, against the original payment:

    * a fee carried from a deferral points at its Intake payment row, so its
      refund keeps `payment_id` (and the existing one-live-refund-per-payment
      index still holds);
    * an imported fee has no payment row this system made: once staff link it
      to its Stripe PaymentIntent (`beginners_workshop_carried_fees
      .stripe_payment_intent_id`, unique), its refund has no `payment_id`, and
      no workshop or Intake when the person has no Intake to attach it to.

  So `workshop_id`, `intake_id` and `payment_id` become nullable, and a check
  keeps every row either a payment's refund or a Carried Fee's. A Carried Fee
  has at most one refund that has not failed.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshop_intake_refunds) do
      add :carried_fee_id,
          references(:beginners_workshop_carried_fees, type: :binary_id, on_delete: :restrict)

      modify :workshop_id, :binary_id, null: true, from: {:binary_id, null: false}
      modify :intake_id, :binary_id, null: true, from: {:binary_id, null: false}
      modify :payment_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create(index(:beginners_workshop_intake_refunds, [:carried_fee_id]))

    create(
      unique_index(:beginners_workshop_intake_refunds, [:carried_fee_id],
        where: "status <> 'failed'",
        name: :beginners_workshop_intake_refunds_one_live_per_fee_index
      )
    )

    create(
      constraint(
        :beginners_workshop_intake_refunds,
        :beginners_workshop_intake_refunds_source_check,
        check:
          "(intake_id IS NULL) = (workshop_id IS NULL) AND " <>
            "(carried_fee_id IS NOT NULL OR (payment_id IS NOT NULL AND intake_id IS NOT NULL))"
      )
    )

    create(
      unique_index(:beginners_workshop_carried_fees, [:stripe_payment_intent_id],
        where: "stripe_payment_intent_id IS NOT NULL",
        name: :beginners_workshop_carried_fees_payment_intent_index
      )
    )

    create(
      constraint(:beginners_workshop_carried_fees, :beginners_workshop_carried_fees_link_check,
        check: "stripe_payment_intent_id IS NULL OR amount_cents IS NOT NULL"
      )
    )
  end
end
