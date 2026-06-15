defmodule Dhc.Repo.Migrations.CreateMemberProfiles do
  use Ecto.Migration

  def up do
    create table(:member_profiles, primary_key: false) do
      add :id, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing),
        primary_key: true

      add :user_profile_id, references(:user_profiles, type: :uuid, on_delete: :delete_all),
        null: false

      add :next_of_kin_name, :text, null: false
      add :next_of_kin_phone, :text, null: false
      add :preferred_weapon, {:array, :preferred_weapon}, null: false
      add :membership_start_date, :timestamptz, default: fragment("NOW()")
      add :membership_end_date, :timestamptz
      add :last_payment_date, :timestamptz
      add :insurance_form_submitted, :boolean, null: false, default: false
      add :additional_data, :map, default: fragment("'{}'::jsonb")
      add :subscription_paused_until, :timestamptz

      timestamps(type: :timestamptz)
    end

    create index(:member_profiles, [:user_profile_id])

    create index(:member_profiles, [:subscription_paused_until],
             where: "subscription_paused_until IS NOT NULL"
           )
  end

  def down do
    drop table(:member_profiles)
  end
end
