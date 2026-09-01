defmodule Dhc.Repo.Migrations.CreateIdempotencyPlugRequests do
  use Ecto.Migration

  def change do
    create table(:idempotency_plug_requests, primary_key: false) do
      add :id, :string, primary_key: true
      add :fingerprint, :string, null: false
      add :data, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:idempotency_plug_requests, [:expires_at])
  end
end
