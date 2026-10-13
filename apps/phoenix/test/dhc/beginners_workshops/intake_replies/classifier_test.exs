defmodule Dhc.BeginnersWorkshops.IntakeReplies.ClassifierTest do
  use ExUnit.Case, async: false

  alias Dhc.BeginnersWorkshops.IntakeReplies.Classifier

  defp json_response(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))

  setup do
    previous_key = Application.get_env(:dhc, :typesafe_api_key)
    Application.put_env(:dhc, :typesafe_api_key, "typesafe-test-key")

    on_exit(fn ->
      if is_nil(previous_key),
        do: Application.delete_env(:dhc, :typesafe_api_key),
        else: Application.put_env(:dhc, :typesafe_api_key, previous_key)
    end)

    :ok
  end

  test "classifies only the extracted reply and the answered email type" do
    Req.Test.stub(Dhc.TypeSafe, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/systemone"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer typesafe-test-key"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "jev-1.13.0"
      assert request["state"] =~ "Please take me off the Waitlist"
      assert request["state"] =~ "Contact — pay for your place"
      assert request["state"] =~ "[email]"
      assert request["state"] =~ "[link]"
      refute request["state"] =~ "jane@example.com"
      refute request["state"] =~ "https://"
      assert request["questions"]["intent"]["type"] == "choice"

      assert Map.keys(request["questions"]["intent"]["criteria"]) |> Enum.sort() ==
               ["cant_make_date", "leaving_waitlist", "something_else"]

      assert request["questions"]["money_back"]["type"] == "noul"

      assert request["questions"]["money_back"]["instructions"] ==
               "Is the person asking for their money back?"

      json_response(
        conn,
        %{
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
          }
        }
      )
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
               ["cant_make_date", "leaving_waitlist"]
             )
  end

  test "uses the intents a notice could lead to and includes something_else" do
    allowed_intents = Classifier.allowed_intents_for_email_type("payment_refunded")

    assert Enum.sort(allowed_intents) ==
             ["leaving_waitlist", "wants_refund", "wants_to_come_back"]

    Req.Test.stub(Dhc.TypeSafe, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["state"] =~ "Payment refunded"

      assert Map.keys(request["questions"]["intent"]["criteria"]) |> Enum.sort() ==
               ["leaving_waitlist", "something_else", "wants_refund", "wants_to_come_back"]

      json_response(
        conn,
        %{
          "model" => "jev-1.13.0",
          "answers" => %{
            "intent" => %{
              "type" => "choice",
              "choice" => "something_else",
              "probabilities" => %{
                "leaving_waitlist" => 0.1,
                "wants_refund" => 0.1,
                "wants_to_come_back" => 0.2,
                "something_else" => 0.6
              },
              "confidence" => 0.6
            },
            "money_back" => %{"type" => "noul", "noul" => 0.5}
          }
        }
      )
    end)

    assert {:ok, %{intent: "something_else", money_back: 0.5}} =
             Classifier.classify("Thanks", "payment_refunded", allowed_intents)
  end

  test "rejects invalid classifier inputs without making an HTTP request" do
    Req.Test.stub(Dhc.TypeSafe, fn _conn -> flunk("did not expect a request") end)

    assert {:error, :invalid_input} = Classifier.classify("", "contact_pay", ["leaving_waitlist"])

    assert {:error, :invalid_input} =
             Classifier.classify("hello", "unknown", ["leaving_waitlist"])

    assert {:error, :invalid_input} =
             Classifier.classify("hello", "contact_pay", ["not_an_intent"])

    assert {:error, :invalid_input} = Classifier.classify("hello", "contact_pay", [])
  end

  test "returns a closed configuration error when the TypeSafe key is absent" do
    Application.delete_env(:dhc, :typesafe_api_key)
    Req.Test.stub(Dhc.TypeSafe, fn _conn -> flunk("did not expect a request") end)

    assert {:error, :not_configured} =
             Classifier.classify("Please take me off the Waitlist", "contact_pay", [
               "leaving_waitlist"
             ])
  end

  test "returns a closed error for malformed provider answers" do
    Req.Test.stub(Dhc.TypeSafe, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"model":"jev-1.13.0","answers":{}}))
    end)

    assert {:error, :invalid_response} =
             Classifier.classify("Please take me off the Waitlist", "contact_pay", [
               "leaving_waitlist"
             ])
  end

  test "retries only rate-limit and overload responses" do
    Process.put(:typesafe_attempt, 0)

    Req.Test.stub(Dhc.TypeSafe, fn conn ->
      attempts = Process.get(:typesafe_attempt, 0) + 1
      Process.put(:typesafe_attempt, attempts)

      case attempts do
        1 ->
          Plug.Conn.resp(conn, 429, ~s({"error":"rate limited"}))

        2 ->
          Plug.Conn.resp(conn, 529, ~s({"error":"overloaded"}))

        _ ->
          json_response(
            conn,
            %{
              "model" => "jev-1.13.0",
              "answers" => %{
                "intent" => %{
                  "type" => "choice",
                  "choice" => "leaving_waitlist",
                  "probabilities" => %{"leaving_waitlist" => 0.9, "something_else" => 0.1},
                  "confidence" => 0.9
                },
                "money_back" => %{"type" => "noul", "noul" => 0.1}
              }
            }
          )
      end
    end)

    assert {:ok, %{intent: "leaving_waitlist"}} =
             Classifier.classify("Please take me off the Waitlist", "contact_pay", [
               "leaving_waitlist"
             ])

    assert Process.get(:typesafe_attempt) == 3
  after
    Process.delete(:typesafe_attempt)
  end

  test "forwards other errors without retrying" do
    Process.put(:typesafe_attempt, 0)

    Req.Test.stub(Dhc.TypeSafe, fn conn ->
      Process.put(:typesafe_attempt, Process.get(:typesafe_attempt) + 1)
      Plug.Conn.resp(conn, 503, ~s({"error":"unavailable"}))
    end)

    assert {:error, {:http_status, 503}} =
             Classifier.classify("Please take me off the Waitlist", "contact_pay", [
               "leaving_waitlist"
             ])

    assert Process.get(:typesafe_attempt) == 1
  after
    Process.delete(:typesafe_attempt)
  end
end
