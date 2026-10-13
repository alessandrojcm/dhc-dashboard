defmodule Dhc.BeginnersWorkshops.IntakeReplies.ClassifierTest do
  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakeReplies.Classifier
  alias Dhc.TypeSafeStub

  setup {Req.Test, :verify_on_exit!}

  @leaving "Please take me off the Waitlist"

  defp classify_leaving, do: Classifier.classify(@leaving, "contact_pay", ["leaving_waitlist"])

  defp respond(body), do: fn conn -> Req.Test.json(conn, body) end

  defp status(code), do: fn conn -> Plug.Conn.send_resp(conn, code, ~s({"error":"x"})) end

  defp ok_leaving do
    fn conn ->
      {request, conn} = TypeSafeStub.request(conn)
      Req.Test.json(conn, TypeSafeStub.answer(request, "leaving_waitlist", 0.9, 0.1))
    end
  end

  describe "the request sent to TypeSafe" do
    test "is exactly the pinned model, the extracted reply with the email type, and two questions" do
      Req.Test.expect(Dhc.TypeSafe, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/systemone"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer typesafe-test-key"]

        {request, conn} = TypeSafeStub.request(conn)

        assert Map.keys(request) |> Enum.sort() == ["model", "questions", "state"]
        assert request["model"] == "jev-1.13.0"

        assert request["state"] ==
                 "Answered email: Contact — pay for your place\n\n" <>
                   "Person's new reply:\n" <>
                   "Please take me off the Waitlist. Contact me at [email]: [link]"

        assert request["questions"] == %{
                 "intent" => %{
                   "type" => "choice",
                   "instructions" => "Which intent best describes what the person is asking for?",
                   "criteria" => %{
                     "cant_make_date" =>
                       "The person cannot attend this Beginners' Workshop date.",
                     "leaving_waitlist" =>
                       "The person wants to leave the Beginners' Workshop Waitlist.",
                     "something_else" =>
                       "The reply does not clearly express one of the listed intents."
                   }
                 },
                 "money_back" => %{
                   "type" => "noul",
                   "instructions" => "Is the person asking for their money back?",
                   "criteria" => %{
                     "true" => "The person is asking for money to be returned.",
                     "false" => "The person is not asking for money to be returned."
                   }
                 }
               }

        Req.Test.json(conn, %{
          "model" => "jev-1.13.0",
          "answers" => %{
            "intent" => %{
              "type" => "choice",
              "choice" => "leaving_waitlist",
              "probabilities" => %{
                "cant_make_date" => 0.15,
                "leaving_waitlist" => 0.8,
                "something_else" => 0.05
              },
              "confidence" => 0.8
            },
            "money_back" => %{"type" => "noul", "noul" => 0.12}
          },
          "usage" => %{"input_tokens" => 100, "output_tokens" => 10}
        })
      end)

      assert {:ok,
              %{
                intent: "leaving_waitlist",
                probabilities: %{
                  "cant_make_date" => 0.15,
                  "leaving_waitlist" => 0.8,
                  "something_else" => 0.05
                },
                confidence: 0.8,
                money_back: 0.12,
                model: "jev-1.13.0"
              }} =
               Classifier.classify(
                 "Please take me off the Waitlist. Contact me at jane@example.com: " <>
                   "https://example.com/reply/k3J9xQ2mT7vLp0aZ",
                 "contact_pay",
                 [:cant_make_date, "leaving_waitlist"]
               )
    end

    test "a notice email offers the notice intents plus something_else" do
      allowed = Classifier.allowed_intents_for_email_type("payment_refunded")
      assert Enum.sort(allowed) == ["leaving_waitlist", "wants_refund", "wants_to_come_back"]

      Req.Test.expect(Dhc.TypeSafe, fn conn ->
        {request, conn} = TypeSafeStub.request(conn)
        assert request["state"] =~ "Answered email: Payment refunded\n"

        assert request |> get_in(["questions", "intent", "criteria"]) |> Map.keys() |> Enum.sort() ==
                 ["leaving_waitlist", "something_else", "wants_refund", "wants_to_come_back"]

        Req.Test.json(conn, TypeSafeStub.answer(request, "something_else", 0.6, 0.5))
      end)

      assert {:ok, %{intent: "something_else", money_back: 0.5}} =
               Classifier.classify("Thanks", "payment_refunded", allowed)
    end
  end

  describe "invalid input is refused before any request" do
    # No expectation is registered, so any request would raise.
    test "empty reply, unknown email type, unknown/duplicate/reserved intents" do
      for {text, type, intents} <- [
            {"", "contact_pay", ["leaving_waitlist"]},
            {"-- \nJane", "contact_pay", ["leaving_waitlist"]},
            {"hello", "unknown", ["leaving_waitlist"]},
            {"hello", "contact_pay", ["not_an_intent"]},
            {"hello", "contact_pay", []},
            {"hello", "contact_pay", ["leaving_waitlist", "leaving_waitlist"]},
            {"hello", "contact_pay", ["leaving_waitlist", "something_else"]}
          ] do
        assert {:error, :invalid_input} = Classifier.classify(text, type, intents),
               "expected #{inspect({text, type, intents})} to be refused"
      end
    end
  end

  describe "an answer the request could not have produced is invalid" do
    setup do
      %{
        valid: %{
          "model" => "jev-1.13.0",
          "answers" => %{
            "intent" => %{
              "type" => "choice",
              "choice" => "leaving_waitlist",
              "probabilities" => %{"leaving_waitlist" => 0.9, "something_else" => 0.1},
              "confidence" => 0.9
            },
            "money_back" => %{"type" => "noul", "noul" => 0.1}
          },
          "usage" => %{"input_tokens" => 100, "output_tokens" => 10}
        }
      }
    end

    test "a well-formed answer is accepted", %{valid: valid} do
      Req.Test.expect(Dhc.TypeSafe, respond(valid))
      assert {:ok, %{intent: "leaving_waitlist"}} = classify_leaving()
    end

    for {name, path, value} <- [
          {"no answers", ["answers"], %{}},
          {"an unpinned model alias", ["model"], "jev-latest"},
          {"another model family", ["model"], "jev-2.0.0"},
          {"an intent that was not offered", ["answers", "intent", "choice"], "wants_refund"},
          {"probabilities for options not offered", ["answers", "intent", "probabilities"],
           %{"leaving_waitlist" => 0.5, "wants_refund" => 0.4, "something_else" => 0.1}},
          {"probabilities missing an offered option", ["answers", "intent", "probabilities"],
           %{"leaving_waitlist" => 1.0}},
          {"a probability above 1", ["answers", "intent", "probabilities"],
           %{"leaving_waitlist" => 1.2, "something_else" => 0.1}},
          {"confidence above 1", ["answers", "intent", "confidence"], 1.5},
          {"negative confidence", ["answers", "intent", "confidence"], -0.1},
          {"money_back above 1", ["answers", "money_back", "noul"], 1.1},
          {"money_back as a choice", ["answers", "money_back", "type"], "choice"},
          {"intent as a noul", ["answers", "intent", "type"], "noul"}
        ] do
      @invalid {path, value}
      test "rejects #{name}", %{valid: valid} do
        {path, value} = @invalid
        Req.Test.expect(Dhc.TypeSafe, respond(put_in(valid, path, value)))
        assert {:error, :invalid_response} = classify_leaving()
      end
    end
  end

  describe "transport" do
    test "retries 429 and 529, then succeeds" do
      Req.Test.expect(Dhc.TypeSafe, status(429))
      Req.Test.expect(Dhc.TypeSafe, status(529))
      Req.Test.expect(Dhc.TypeSafe, ok_leaving())

      assert {:ok, %{intent: "leaving_waitlist"}} = classify_leaving()
    end

    test "gives up after three retries of a persistent 429" do
      Req.Test.expect(Dhc.TypeSafe, 4, status(429))
      assert {:error, {:http_status, 429}} = classify_leaving()
    end

    test "does not retry other server errors" do
      Req.Test.expect(Dhc.TypeSafe, status(503))
      assert {:error, {:http_status, 503}} = classify_leaving()
    end

    test "does not retry a transport failure, and returns a closed error" do
      Req.Test.expect(Dhc.TypeSafe, &Req.Test.transport_error(&1, :timeout))
      assert {:error, :transport} = classify_leaving()
    end
  end
end
