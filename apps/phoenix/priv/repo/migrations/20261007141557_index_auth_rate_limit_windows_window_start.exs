defmodule Dhc.Repo.Migrations.IndexAuthRateLimitWindowsWindowStart do
  @moduledoc """
  `Dhc.Auth.Retention` deletes magic-link rate-limit windows by
  `window_start < cutoff`. The only existing index is `UNIQUE (key,
  window_start)`, which cannot serve a range scan on `window_start` alone.
  """

  use Ecto.Migration

  def change do
    create index(:auth_rate_limit_windows, [:window_start])
  end
end
