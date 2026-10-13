defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopIntakeReplies do
  use Ecto.Migration

  def change do
    create table(:beginners_workshop_intake_replies, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :resend_email_id, :text, null: false

      # The binding the reply was addressed to; none means unrecognised. The
      # person's hard delete removes the row explicitly (IntakeReplies
      # delete_for_person/1); the cascade covers any other entry deletion.
      add :reply_address_id,
          references(:beginners_workshop_intake_reply_addresses,
            type: :binary_id,
            on_delete: :delete_all
          )

      add :received_at, :utc_datetime_usec, null: false
      add :outcome, :text, null: false, default: "pending"
      add :outcome_reason, :text
      add :forward_sent_id, :text
      add :forwarded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:beginners_workshop_intake_replies, [:resend_email_id])
    create index(:beginners_workshop_intake_replies, [:reply_address_id])

    create constraint(
             :beginners_workshop_intake_replies,
             :beginners_workshop_intake_replies_outcome_check,
             check:
               "outcome IN ('pending', 'forwarded', 'done', 'needs_you', 'unrecognised', 'automated', 'refused')"
           )
  end
end
