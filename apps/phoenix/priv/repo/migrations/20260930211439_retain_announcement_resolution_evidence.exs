defmodule Dhc.Repo.Migrations.RetainAnnouncementResolutionEvidence do
  use Ecto.Migration

  def change do
    alter table(:discord_announcement_deliveries) do
      add(:resolved_outcome, :string)
      add(:precedence_chain, {:array, :string}, null: false, default: [])
    end
  end
end
