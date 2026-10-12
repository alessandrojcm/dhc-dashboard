defmodule Mix.Tasks.Dhc.Waitlist.ImportTest do
  use Dhc.DataCase, async: false

  alias Dhc.Waitlist.WaitlistEntry

  @sample Path.expand("../../fixtures/waitlist_import/sample.tsv", __DIR__)
  @month_first Path.expand("../../fixtures/waitlist_import/month_first.tsv", __DIR__)

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "--dry-run prints the full report and writes nothing" do
    Mix.Tasks.Dhc.Waitlist.Import.run([@sample, "--dry-run"])

    assert_received {:mix_shell, :info, ["Waitlist import: DRY RUN (nothing written)." <> _]}
    assert_received {:mix_shell, :info, ["Refused:"]}
    refute Repo.exists?(WaitlistEntry)
  end

  test "imports and prints the report" do
    Mix.Tasks.Dhc.Waitlist.Import.run([@sample])

    assert_received {:mix_shell, :info, ["Waitlist import: IMPORTED." <> _]}
    assert Repo.exists?(WaitlistEntry)
  end

  test "a refused sheet raises and writes nothing" do
    assert_raise Mix.Error, ~r/month-first/, fn ->
      Mix.Tasks.Dhc.Waitlist.Import.run([@month_first])
    end

    refute Repo.exists?(WaitlistEntry)
  end

  test "usage" do
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Dhc.Waitlist.Import.run([]) end
  end
end
