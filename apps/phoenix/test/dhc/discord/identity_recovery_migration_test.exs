defmodule Dhc.Discord.IdentityRecoveryMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260814130000_ale_221_complete_discord_identity_recovery.exs",
                    __DIR__
                  )

  test "ALE-221 refuses destructive rollback and directs operators to roll forward" do
    Code.require_file(@migration_path)

    assert_raise RuntimeError, ~r/intentionally irreversible.*Roll forward/s, fn ->
      Dhc.Repo.Migrations.Ale221CompleteDiscordIdentityRecovery.down()
    end
  end
end
