defmodule Mix.Tasks.Dhc.IntakeReplies.EvalTest do
  # Mix.shell is global, so this cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias Dhc.TypeSafeStub
  alias Mix.Tasks.Dhc.IntakeReplies.Eval, as: EvalTask

  @reply "Sorry, I cannot attend the date in November"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp printed do
    receive do
      {:mix_shell, _level, [line]} -> [line | printed()]
    after
      0 -> []
    end
  end

  @tag :tmp_dir
  test "prints aggregates for every intent and never the reply text", %{tmp_dir: dir} do
    path = Path.join(dir, "labelled.csv")

    File.write!(
      path,
      "email type answered,reply as pasted,intent,money back yes/no\n" <>
        "contact_pay,\"#{@reply}\",cant_make_date,no\n"
    )

    Req.Test.expect(
      Dhc.TypeSafe,
      TypeSafeStub.by_reply(%{@reply => {"cant_make_date", 0.9, 0.1}})
    )

    EvalTask.run([path])
    output = printed()

    assert "Intake Reply Jev eval: 1 rows; 0 empty after extraction" in output
    assert "money_back agreement: 1/1 (100.0%)" in output
    assert "cant_make_date: 1 examples" in output
    assert "  90.0%: 1 actions, 0 wrong, 0 to coordinator" in output
    assert "  recommended: stay off (fewer than 20 examples)" in output

    for intent <- ~w(leaving_waitlist wants_refund wants_to_come_back link_problem something_else) do
      assert "#{intent}: 0 examples" in output
    end

    for line <- output do
      refute line =~ "cannot attend"
      refute line =~ "November"
    end
  end

  @tag :tmp_dir
  test "a failed row raises without echoing the reply", %{tmp_dir: dir} do
    path = Path.join(dir, "labelled.csv")

    File.write!(
      path,
      "email type answered,reply as pasted,intent,money back yes/no\n" <>
        "contact_pay,\"#{@reply}\",cant_make_date,no\n"
    )

    Req.Test.expect(Dhc.TypeSafe, &Plug.Conn.send_resp(&1, 503, "{}"))

    error = assert_raise Mix.Error, fn -> EvalTask.run([path]) end

    assert error.message ==
             "Intake Reply eval failed: row 2 could not be classified (http_status_503)"
  end

  test "usage" do
    assert_raise Mix.Error, ~r/usage/, fn -> EvalTask.run([]) end
  end
end
