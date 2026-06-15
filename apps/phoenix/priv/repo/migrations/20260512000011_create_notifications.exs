defmodule Dhc.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def up do
    create table(:notifications, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, :uuid, null: false
      add :body, :text, null: false
      add :created_at, :timestamptz, null: false, default: fragment("NOW()")
      add :read_at, :timestamptz
    end

    create index(:notifications, [:user_id])
    create index(:notifications, [:created_at])
  end

  def down do
    drop table(:notifications)
  end
end
