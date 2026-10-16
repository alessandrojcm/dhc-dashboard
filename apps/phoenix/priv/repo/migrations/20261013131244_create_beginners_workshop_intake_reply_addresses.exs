defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopIntakeReplyAddresses do
  use Ecto.Migration

  def change do
    create table(:beginners_workshop_intake_reply_addresses, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :waitlist_id,
          references(:waitlist, type: :binary_id, on_delete: :delete_all),
          null: false

      add :intake_id,
          references(:beginners_workshop_intakes, type: :binary_id, on_delete: :nilify_all)

      add :email_type, :text, null: false
      add :token_hash, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:beginners_workshop_intake_reply_addresses, [:token_hash])
    create index(:beginners_workshop_intake_reply_addresses, [:waitlist_id])
    create index(:beginners_workshop_intake_reply_addresses, [:intake_id])

    create constraint(
             :beginners_workshop_intake_reply_addresses,
             :beginners_workshop_intake_reply_addresses_token_hash_check,
             check: "octet_length(token_hash) = 32"
           )
  end
end
