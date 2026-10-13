defmodule Dhc.BeginnersWorkshops.IntakeReplies.EvalTest do
  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakeReplies.Eval

  test "reads multiline CSV, extracts before classification and reports aggregate thresholds only" do
    path =
      Path.join(System.tmp_dir!(), "intake-reply-eval-#{System.unique_integer([:positive])}.csv")

    File.write!(
      path,
      "Email type answered,Reply as pasted,Intent,Money back yes/no\r\n" <>
        "contact_pay,\"I cannot attend,\nplease contact me next month\",cant_make_date,no\r\n" <>
        "contact_pay,\"Please take me off the Waitlist\",leaving_waitlist,yes\r\n" <>
        "follow_up,\"I need to leave the list\",leaving_waitlist,no\r\n"
    )

    on_exit(fn -> File.rm(path) end)

    parent = self()

    classify = fn text, email_type, allowed_intents ->
      send(parent, {:classified, text, email_type, allowed_intents})

      case text do
        "I cannot attend,\nplease contact me next month" ->
          {:ok,
           %{
             intent: "cant_make_date",
             probabilities: %{
               "cant_make_date" => 0.96,
               "leaving_waitlist" => 0.02,
               "something_else" => 0.02
             },
             confidence: 0.96,
             money_back: 0.1,
             model: "jev-1.13.0"
           }}

        "Please take me off the Waitlist" ->
          {:ok,
           %{
             intent: "something_else",
             probabilities: %{
               "cant_make_date" => 0.02,
               "leaving_waitlist" => 0.08,
               "something_else" => 0.9
             },
             confidence: 0.9,
             money_back: 0.8,
             model: "jev-1.13.0"
           }}

        "I need to leave the list" ->
          {:ok,
           %{
             intent: "cant_make_date",
             probabilities: %{
               "leaving_waitlist" => 0.1,
               "wants_refund" => 0.1,
               "wants_to_come_back" => 0.1,
               "something_else" => 0.7
             },
             confidence: 0.9,
             money_back: 0.1,
             model: "jev-1.13.0"
           }}
      end
    end

    assert {:ok, report} = Eval.run(path, classify: classify)

    assert report.total == 3
    assert report.empty_replies == 0
    assert report.money_back == %{examples: 3, agreement: 3, accuracy: 1.0}

    assert report.by_intent["cant_make_date"].examples == 1

    assert report.by_intent["cant_make_date"].thresholds[0.9] == %{
             actions_taken: 2,
             wrong_actions: 1,
             coordinator: 1
           }

    assert report.by_intent["cant_make_date"].recommended_threshold ==
             "stay off (fewer than 20 examples)"

    assert report.by_intent["something_else"].recommended_threshold == "stay off (not an action)"

    assert_received {:classified, "I cannot attend,\nplease contact me next month", "contact_pay",
                     [
                       "cant_make_date",
                       "leaving_waitlist",
                       "wants_refund",
                       "wants_to_come_back",
                       "link_problem"
                     ]}

    assert_received {:classified, "Please take me off the Waitlist", "contact_pay",
                     [
                       "cant_make_date",
                       "leaving_waitlist",
                       "wants_refund",
                       "wants_to_come_back",
                       "link_problem"
                     ]}

    assert_received {:classified, "I need to leave the list", "follow_up",
                     ["leaving_waitlist", "wants_refund", "wants_to_come_back"]}

    refute inspect(report) =~ "I cannot attend"
    refute inspect(report) =~ "Please take me off"
  end

  test "accepts a TSV file and reports empty extracted replies without calling Jev" do
    path =
      Path.join(System.tmp_dir!(), "intake-reply-eval-#{System.unique_integer([:positive])}.tsv")

    File.write!(
      path,
      "Email type answered\tReply as pasted\tIntent\tMoney back yes/no\n" <>
        "contact_pay\t\"-- \nJane Doe\"\tcant_make_date\tno\n"
    )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, report} =
             Eval.run(path,
               classify: fn _text, _type, _allowed -> flunk("empty text is not classified") end
             )

    assert report.total == 1
    assert report.empty_replies == 1
    assert report.money_back == %{examples: 0, agreement: 0, accuracy: nil}

    assert Enum.all?(report.by_intent, fn {_intent, item} ->
             item.thresholds[0.5].coordinator == 1
           end)
  end

  test "refuses invalid labels without echoing the reply text" do
    path =
      Path.join(System.tmp_dir!(), "intake-reply-eval-#{System.unique_integer([:positive])}.csv")

    File.write!(
      path,
      "email type answered,reply as pasted,intent,money back yes/no\ncontact_pay,private reply,unknown,no\n"
    )

    on_exit(fn -> File.rm(path) end)

    assert {:error, message} =
             Eval.run(path, classify: fn _, _, _ -> flunk("invalid labels are rejected") end)

    assert message =~ "row 2"
    refute message =~ "private reply"
  end

  test "recommends the lowest threshold with no wrong actions once there are 20 examples" do
    path =
      Path.join(System.tmp_dir!(), "intake-reply-eval-#{System.unique_integer([:positive])}.csv")

    rows =
      for index <- 1..21 do
        if index <= 20,
          do: "contact_pay,\"I cannot attend this date\",cant_make_date,no",
          else: "follow_up,\"Please take me off the list\",leaving_waitlist,no"
      end

    File.write!(
      path,
      "email type answered,reply as pasted,intent,money back yes/no\n" <> Enum.join(rows, "\n")
    )

    on_exit(fn -> File.rm(path) end)

    classify = fn
      "I cannot attend this date", _type, _allowed ->
        {:ok, %{intent: "cant_make_date", confidence: 0.6, money_back: 0.1}}

      "Please take me off the list", _type, _allowed ->
        {:ok, %{intent: "cant_make_date", confidence: 0.55, money_back: 0.1}}
    end

    assert {:ok, report} = Eval.run(path, classify: classify)

    assert report.by_intent["cant_make_date"].examples == 20

    assert report.by_intent["cant_make_date"].thresholds[0.55] == %{
             actions_taken: 21,
             wrong_actions: 1,
             coordinator: 0
           }

    assert report.by_intent["cant_make_date"].thresholds[0.6] == %{
             actions_taken: 20,
             wrong_actions: 0,
             coordinator: 1
           }

    assert report.by_intent["cant_make_date"].recommended_threshold == 0.6
  end
end
