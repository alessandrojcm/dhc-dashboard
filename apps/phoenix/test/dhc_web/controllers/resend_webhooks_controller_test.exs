defmodule DhcWeb.ResendWebhooksControllerTest do
  @moduledoc """
  ALE-409 contract test for `POST /api/webhooks/resend`: Svix signature
  verification, the `email.received` → Intake Reply → one forward path, and
  that reply addresses never reach a log.
  """

  use DhcWeb.ConnCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Swoosh.TestAssertions
  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops.{IntakeReplies, IntakeReply}
  alias Dhc.BeginnersWorkshops.Workers.ReplyWorker
  alias Dhc.Repo
  alias Dhc.ResendReceivingStub

  @domain "reply.example.test"

  setup do
    original_domain = Application.get_env(:dhc, :intake_reply_domain)
    Application.put_env(:dhc, :intake_reply_domain, @domain)

    on_exit(fn ->
      if is_nil(original_domain),
        do: Application.delete_env(:dhc, :intake_reply_domain),
        else: Application.put_env(:dhc, :intake_reply_domain, original_domain)
    end)

    :ok
  end

  defp received_event(email_id, to) do
    Jason.encode!(%{
      "type" => "email.received",
      "created_at" => "2026-10-13T12:00:00.000Z",
      "data" => %{
        "email_id" => email_id,
        "from" => "person@example.com",
        "to" => List.wrap(to),
        "subject" => "Re: Your workshop place",
        "attachments" => []
      }
    })
  end

  defp deliver(conn, payload, headers \\ nil) do
    headers = headers || ResendReceivingStub.signed_headers(payload)

    headers
    |> Enum.reduce(put_req_header(conn, "content-type", "application/json"), fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
    |> post("/api/webhooks/resend", payload)
  end

  defp run_jobs do
    for job <- all_enqueued(worker: ReplyWorker),
        do: assert(:ok = perform_job(ReplyWorker, job.args))
  end

  defp forwarded do
    assert_email_sent(fn email ->
      send(self(), {:forwarded, email})
      true
    end)

    assert_receive {:forwarded, email}
    email
  end

  test "records a signed reply, queues one forward and never logs the address", %{conn: conn} do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    {:ok, address} = IntakeReplies.reply_to(person, nil, "declined")
    email_id = Ecto.UUID.generate()
    payload = received_event(email_id, address)

    Logger.put_process_level(self(), :debug)
    on_exit(fn -> Logger.delete_process_level(self()) end)

    logs =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        response = deliver(conn, payload)

        assert %{"data" => %{"received" => true, "handled" => true}} =
                 json_response(response, 200)
      end)

    refute logs =~ address
    refute logs =~ String.split(address, "@") |> hd()
    assert [%{args: args}] = all_enqueued(worker: ReplyWorker)
    assert args == %{"resend_email_id" => email_id}
    assert %IntakeReply{outcome: "pending"} = Repo.get_by!(IntakeReply, resend_email_id: email_id)

    ResendReceivingStub.stub(email_id)
    run_jobs()
    assert forwarded().subject == "[Needs you] Re: Your workshop place"
  end

  test "a redelivered webhook changes nothing", %{conn: conn} do
    email_id = Ecto.UUID.generate()
    payload = received_event(email_id, "unknown@#{@domain}")

    assert json_response(deliver(conn, payload), 200)
    assert json_response(deliver(build_conn(), payload), 200)

    assert Repo.aggregate(IntakeReply, :count) == 1
    assert [_one_job] = all_enqueued(worker: ReplyWorker)
  end

  test "an address that resolves to nothing is forwarded as [Unrecognised]", %{conn: conn} do
    email_id = Ecto.UUID.generate()
    assert json_response(deliver(conn, received_event(email_id, "nobody@#{@domain}")), 200)

    ResendReceivingStub.stub(email_id, email: %{"subject" => "Hello"})
    run_jobs()

    assert forwarded().subject == "[Unrecognised] Hello"

    assert %IntakeReply{outcome: "unrecognised", reply_address_id: nil} =
             Repo.get_by!(IntakeReply, resend_email_id: email_id)
  end

  test "a reply that cannot be rebuilt is forwarded with the original as .eml", %{conn: conn} do
    email_id = Ecto.UUID.generate()
    assert json_response(deliver(conn, received_event(email_id, "nobody@#{@domain}")), 200)

    ResendReceivingStub.stub(email_id, raw: "original bytes", fail: [:attachments])
    run_jobs()

    assert [
             %{
               filename: "forwarded_message.eml",
               content_type: "message/rfc822",
               data: "original bytes"
             }
           ] = forwarded().attachments
  end

  test "acknowledges and ignores every other event type", %{conn: conn} do
    payload = Jason.encode!(%{"type" => "email.delivered", "data" => %{"email_id" => "x"}})

    assert %{"data" => %{"received" => true, "handled" => false}} =
             json_response(deliver(conn, payload), 200)

    assert Repo.aggregate(IntakeReply, :count) == 0
    assert [] = all_enqueued(worker: ReplyWorker)
  end

  test "acknowledges a reply without recording it while Intake Replies is parked", %{conn: conn} do
    original = Application.get_env(:dhc, IntakeReplies)
    Application.put_env(:dhc, IntakeReplies, enabled: false)
    on_exit(fn -> Application.put_env(:dhc, IntakeReplies, original) end)

    email_id = Ecto.UUID.generate()
    payload = received_event(email_id, "nobody@#{@domain}")

    assert %{"data" => %{"received" => true, "handled" => false}} =
             json_response(deliver(conn, payload), 200)

    assert Repo.aggregate(IntakeReply, :count) == 0
    assert [] = all_enqueued(worker: ReplyWorker)

    # Parking the feature does not open the endpoint: the signature is still
    # verified before anything is decided.
    assert json_response(deliver(build_conn(), payload, []), 401)
  end

  test "refuses an invalid signature", %{conn: conn} do
    payload = received_event(Ecto.UUID.generate(), "nobody@#{@domain}")

    [{"svix-id", id}, {"svix-timestamp", ts}, _signature] =
      ResendReceivingStub.signed_headers(payload)

    response =
      deliver(conn, payload, [
        {"svix-id", id},
        {"svix-timestamp", ts},
        {"svix-signature", "v1," <> Base.encode64("forged")}
      ])

    assert json_response(response, 401) == %{"errors" => %{"detail" => "Invalid signature"}}
    assert Repo.aggregate(IntakeReply, :count) == 0
  end

  test "refuses a signature over another body", %{conn: conn} do
    payload = received_event(Ecto.UUID.generate(), "nobody@#{@domain}")
    headers = ResendReceivingStub.signed_headers(payload <> " ")

    assert json_response(deliver(conn, payload, headers), 401)
  end

  test "refuses a stale timestamp", %{conn: conn} do
    payload = received_event(Ecto.UUID.generate(), "nobody@#{@domain}")
    headers = ResendReceivingStub.signed_headers(payload, System.system_time(:second) - 600)

    assert json_response(deliver(conn, payload, headers), 401)["errors"]["detail"] =~ "Timestamp"
  end

  test "refuses a delivery without signature headers", %{conn: conn} do
    payload = received_event(Ecto.UUID.generate(), "nobody@#{@domain}")
    assert json_response(deliver(conn, payload, []), 401)
  end
end
