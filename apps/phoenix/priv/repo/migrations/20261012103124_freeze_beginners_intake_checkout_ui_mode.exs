defmodule Dhc.Repo.Migrations.FreezeBeginnersIntakeCheckoutUiMode do
  use Ecto.Migration

  def change do
    alter table(:beginners_workshop_intake_payments) do
      # Existing holds must replay their original hosted parameters.
      add :checkout_ui_mode, :text, null: false, default: "hosted"
    end
  end
end
