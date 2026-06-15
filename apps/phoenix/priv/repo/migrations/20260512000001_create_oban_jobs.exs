defmodule Dhc.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migrations.up(prefix: "public")
  end

  def down do
    Oban.Migrations.down(prefix: "public")
  end
end
