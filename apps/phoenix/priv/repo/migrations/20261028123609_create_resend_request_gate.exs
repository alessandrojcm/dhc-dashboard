defmodule Dhc.Repo.Migrations.CreateResendRequestGate do
  use Ecto.Migration

  def change do
    # Additive deployment: one shared provider gate, no personal data.
    create table(:resend_request_gate, primary_key: false) do
      add :name, :text, primary_key: true
      add :next_at_ms, :bigint, null: false
    end
  end
end
