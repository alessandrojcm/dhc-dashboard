defmodule Dhc.BeginnersWorkshops.IntakeReplies.EvalTest do
  # Every reply here is synthetic. Eval runs the real Classifier, so TypeSafe
  # is stubbed with `Req.Test` and every answer is one the API could return.
  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakeReplies.Eval
  alias Dhc.TypeSafeStub

  @header "email type answered,reply as pasted,intent,money back yes/no\n"
  @action_intents [
    "cant_make_date",
    "leaving_waitlist",
    "link_problem",
    "something_else",
    "wants_refund",
    "wants_to_come_back"
  ]
  @notice_intents ["leaving_waitlist", "something_else", "wants_refund", "wants_to_come_back"]

  setup {Req.Test, :verify_on_exit!}

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp csv(dir, rows), do: write!(dir, "labelled.csv", @header <> Enum.join(rows, "\n") <> "\n")

  @tag :tmp_dir
  test "multiline CSV: each row extracted, offered its email type's intents, aggregated", %{
    tmp_dir: dir
  } do
    path =
      write!(
        dir,
        "labelled.csv",
        "Email type answered,Reply as pasted,Intent,Money back yes/no\r\n" <>
          "contact_pay,\"I cannot attend,\nplease contact me next month\",cant_make_date,no\r\n" <>
          "contact_pay,\"Please take me off the Waitlist\n\nOn Mon, 12 Oct 2026 at 10:00, " <>
          "Dublin HEMA Club <noreply@dublinhemaclub.com> wrote:\n> Pay here\",leaving_waitlist,yes\r\n" <>
          "follow_up,\"I need to leave the list\",leaving_waitlist,no\r\n"
      )

    answers = %{
      "I cannot attend,\nplease contact me next month" => {"cant_make_date", 0.96, 0.1},
      "Please take me off the Waitlist" => {"something_else", 0.9, 0.8},
      "I need to leave the list" => {"wants_to_come_back", 0.9, 0.1}
    }

    Req.Test.expect(Dhc.TypeSafe, 3, fn conn ->
      {request, conn} = TypeSafeStub.request(conn)
      text = TypeSafeStub.reply_text(request)

      offered =
        request |> get_in(["questions", "intent", "criteria"]) |> Map.keys() |> Enum.sort()

      send(self(), {:offered, text, offered})
      {intent, confidence, money_back} = Map.fetch!(answers, text)
      Req.Test.json(conn, TypeSafeStub.answer(request, intent, confidence, money_back))
    end)

    assert {:ok, report} = Eval.run(path)

    # The quoted history was cut before Jev saw the second reply.
    assert_received {:offered, "I cannot attend,\nplease contact me next month", @action_intents}
    assert_received {:offered, "Please take me off the Waitlist", @action_intents}
    assert_received {:offered, "I need to leave the list", @notice_intents}

    assert report.total == 3
    assert report.empty_replies == 0
    assert report.money_back == %{examples: 3, agreement: 3, accuracy: 1.0}

    assert report.by_intent["cant_make_date"].examples == 1

    assert report.by_intent["cant_make_date"].thresholds[0.9] ==
             %{actions_taken: 1, wrong_actions: 0, coordinator: 2}

    assert report.by_intent["wants_to_come_back"].thresholds[0.9] ==
             %{actions_taken: 1, wrong_actions: 1, coordinator: 2}

    assert report.by_intent["wants_to_come_back"].thresholds[0.95] ==
             %{actions_taken: 0, wrong_actions: 0, coordinator: 3}

    assert report.by_intent["cant_make_date"].recommended_threshold ==
             "stay off (fewer than 20 examples)"

    assert report.by_intent["something_else"].recommended_threshold == "stay off (not an action)"

    assert report.by_intent["something_else"].thresholds[0.5] ==
             %{actions_taken: 0, wrong_actions: 0, coordinator: 3}

    refute inspect(report) =~ "cannot attend"
    refute inspect(report) =~ "take me off"
  end

  @tag :tmp_dir
  test "a TSV reply that is only a signature is counted empty and never sent", %{tmp_dir: dir} do
    path =
      write!(
        dir,
        "labelled.tsv",
        "Email type answered\tReply as pasted\tIntent\tMoney back yes/no\n" <>
          "contact_pay\t\"-- \nJane Doe\"\tcant_make_date\tNo\n"
      )

    # No expectation: a request would raise.
    assert {:ok, report} = Eval.run(path)
    assert report.total == 1
    assert report.empty_replies == 1
    assert report.money_back == %{examples: 0, agreement: 0, accuracy: nil}
    assert Enum.all?(report.by_intent, fn {_, item} -> item.thresholds[0.5].coordinator == 1 end)
  end

  describe "recommendations need 20 examples and a threshold with no wrong action" do
    @tag :tmp_dir
    test "the lowest such threshold is recommended", %{tmp_dir: dir} do
      right = List.duplicate("contact_pay,\"I cannot attend this date\",cant_make_date,no", 20)
      wrong = "contact_pay,\"Please take me off the list\",leaving_waitlist,no"

      Req.Test.expect(
        Dhc.TypeSafe,
        21,
        TypeSafeStub.by_reply(%{
          "I cannot attend this date" => {"cant_make_date", 0.6, 0.1},
          "Please take me off the list" => {"cant_make_date", 0.55, 0.1}
        })
      )

      assert {:ok, report} = Eval.run(csv(dir, right ++ [wrong]))
      item = report.by_intent["cant_make_date"]

      assert item.examples == 20
      assert item.thresholds[0.55] == %{actions_taken: 21, wrong_actions: 1, coordinator: 0}
      assert item.thresholds[0.6] == %{actions_taken: 20, wrong_actions: 0, coordinator: 1}
      assert item.recommended_threshold == 0.6
    end

    @tag :tmp_dir
    test "an intent wrong even at its most confident stays off", %{tmp_dir: dir} do
      right = List.duplicate("contact_pay,\"I cannot attend this date\",cant_make_date,no", 20)
      wrong = "contact_pay,\"Please take me off the list\",leaving_waitlist,no"

      Req.Test.expect(
        Dhc.TypeSafe,
        21,
        TypeSafeStub.by_reply(%{
          "I cannot attend this date" => {"cant_make_date", 0.96, 0.1},
          "Please take me off the list" => {"cant_make_date", 0.97, 0.1}
        })
      )

      assert {:ok, report} = Eval.run(csv(dir, right ++ [wrong]))

      assert report.by_intent["cant_make_date"].recommended_threshold ==
               "stay off (no zero-error threshold)"
    end
  end

  describe "refusals name the row, never its text" do
    @tag :tmp_dir
    test "an invalid label", %{tmp_dir: dir} do
      path = csv(dir, ["contact_pay,private reply,unknown,no"])

      assert {:error, message} = Eval.run(path)
      assert message == "row 2 has invalid labels"
    end

    @tag :tmp_dir
    test "a TypeSafe failure", %{tmp_dir: dir} do
      Req.Test.expect(Dhc.TypeSafe, &Plug.Conn.send_resp(&1, 503, "{}"))
      path = csv(dir, ["contact_pay,\"private reply about my refund\",wants_refund,yes"])

      assert {:error, "row 2 could not be classified (http_status_503)"} = Eval.run(path)
    end

    @tag :tmp_dir
    test "an answer offering an intent the answered email cannot lead to", %{tmp_dir: dir} do
      # A notice email does not offer cant_make_date, so Jev cannot pick it;
      # an answer that does is refused, not scored.
      Req.Test.expect(
        Dhc.TypeSafe,
        TypeSafeStub.by_reply(%{"private reply" => {"cant_make_date", 0.9, 0.1}})
      )

      path = csv(dir, ["follow_up,\"private reply\",leaving_waitlist,no"])

      assert {:error, "row 2 could not be classified (invalid_response)"} = Eval.run(path)
    end

    @tag :tmp_dir
    test "a missing column and an empty file", %{tmp_dir: dir} do
      missing =
        write!(dir, "missing.csv", "email type answered,intent\ncontact_pay,leaving_waitlist\n")

      assert {:error, "the eval file is missing a required column"} = Eval.run(missing)

      assert {:error, "the eval file is empty"} = Eval.run(write!(dir, "empty.csv", ""))
    end
  end
end
