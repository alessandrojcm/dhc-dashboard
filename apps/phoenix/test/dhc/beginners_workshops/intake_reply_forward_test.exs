defmodule Dhc.BeginnersWorkshops.IntakeReplyForwardTest do
  @moduledoc """
  ALE-409: every Intake Reply is recorded once and forwarded once to the
  club inbox — rebuilt when it can be, the original as `.eml` when it cannot,
  the banner alone when even that is too large or the reply cannot be read,
  and a coordinator alert when the forward cannot be sent at all.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Swoosh.TestAssertions
  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{IntakeReplies, IntakeReply}
  alias Dhc.BeginnersWorkshops.IntakeReplies.Forward
  alias Dhc.BeginnersWorkshops.Workers.ReplyWorker
  alias Dhc.Email.Mailer
  alias Dhc.Notifications.Notification
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

  defp resend_id, do: Ecto.UUID.generate()

  defp person_with_address(type \\ "withdrawn_forfeited", intake_id \\ nil) do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z], first_name: "Aoife")
    {:ok, address} = IntakeReplies.reply_to(person, intake_id, type)
    {person, address}
  end

  defp receive!(id, to) do
    assert {:ok, :recorded} =
             IntakeReplies.record_received(%{"email_id" => id, "to" => List.wrap(to)})
  end

  defp reply(id), do: Repo.get_by!(IntakeReply, resend_email_id: id)

  defp forwarded do
    assert_email_sent(fn email ->
      send(self(), {:forwarded, email})
      true
    end)

    assert_receive {:forwarded, email}
    email
  end

  describe "record_received/2" do
    test "records the binding and queues one job; a redelivery changes nothing" do
      {_person, address} = person_with_address()
      id = resend_id()

      receive!(id, "Aoife <#{address}>")
      assert %IntakeReply{outcome: "pending", reply_address_id: binding_id} = reply(id)
      assert is_binary(binding_id)
      assert [%{args: %{"resend_email_id" => ^id}}] = all_enqueued(worker: ReplyWorker)

      assert {:ok, :duplicate} =
               IntakeReplies.record_received(%{"email_id" => id, "to" => [address]})

      assert Repo.aggregate(IntakeReply, :count) == 1
      assert [_one_job] = all_enqueued(worker: ReplyWorker)
    end

    test "an address that resolves to nothing is recorded without a binding" do
      id = resend_id()
      receive!(id, "nobody@#{@domain}")
      assert %IntakeReply{reply_address_id: nil} = reply(id)
    end

    test "refuses a payload without a usable email id" do
      assert {:error, :invalid_payload} = IntakeReplies.record_received(%{"to" => []})

      assert {:error, :invalid_payload} =
               IntakeReplies.record_received(%{"email_id" => "../../emails"})
    end
  end

  describe "forward/2" do
    test "rebuilds the reply with the banner, Reply-To and inline attachments" do
      {person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)

      ResendReceivingStub.stub(id,
        email: %{
          "html" => ~s(<html><body><p>Count me out <img src="cid:img001"></p></body></html>),
          "subject" => "Re: Withdrawn"
        },
        attachments: [
          {%{
             "filename" => "logo.png",
             "content_type" => "image/png",
             "content_disposition" => "inline",
             "content_id" => "img001"
           }, "png-bytes"},
          {%{"filename" => "letter.pdf", "content_type" => "application/pdf"}, "pdf-bytes"}
        ]
      )

      assert {:ok, :forwarded} = IntakeReplies.forward(id)
      email = forwarded()

      assert email.subject == "[Needs you] Re: Withdrawn"
      assert email.to == [{"", "contact@dublinhemaclub.com"}]
      assert email.reply_to == {"", "person@example.com"}
      assert email.provider_options[:idempotency_key] == "intake-reply-forward:#{id}"
      assert email.html_body =~ ~r{<body><div [^>]*>Reply from Aoife Waiting}
      assert email.html_body =~ "Withdrawn: payment kept"
      assert email.html_body =~ "/dashboard/beginners-workshop/waitlist"
      assert email.html_body =~ ~s(<img src="cid:img001">)
      assert email.text_body =~ "Reply from Aoife Waiting"

      assert [inline, file] = email.attachments
      assert %{filename: "logo.png", type: :inline, cid: "img001", data: "png-bytes"} = inline
      assert %{filename: "letter.pdf", type: :attachment, data: "pdf-bytes"} = file

      assert %IntakeReply{outcome: "needs_you", outcome_reason: "sender_mismatch"} =
               row = reply(id)

      assert %DateTime{} = row.forwarded_at
      refute email.html_body =~ address
      refute email.html_body =~ person.email
    end

    test "links a reply about an Intake to its workshop's Manage page" do
      coordinator = staff_fixture()
      workshop = scheduled_fixture(coordinator)
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      {intake, _token} = intake_fixture!(workshop.id, person)
      {:ok, address} = IntakeReplies.reply_to(person, intake.id, "contact_pay")
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id)

      assert {:ok, :forwarded} = IntakeReplies.forward(id)
      email = forwarded()
      assert email.html_body =~ "/dashboard/beginners-workshop/workshops/#{workshop.id}"
      assert email.html_body =~ "Place offer: payment needed"
    end

    test "escapes the banner" do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z], first_name: "<b>Aoife</b>")
      {:ok, address} = IntakeReplies.reply_to(person, nil, "declined")
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id)

      assert {:ok, :forwarded} = IntakeReplies.forward(id)
      email = forwarded()
      assert email.html_body =~ "&lt;b&gt;Aoife&lt;/b&gt;"
      refute email.html_body =~ "<b>Aoife</b>"
    end

    test "an unknown address is forwarded as [Unrecognised]" do
      id = resend_id()
      receive!(id, "nobody@#{@domain}")
      ResendReceivingStub.stub(id, email: %{"subject" => "Hello"})

      assert {:ok, :forwarded} = IntakeReplies.forward(id)
      assert forwarded().subject == "[Unrecognised] Hello"

      assert %IntakeReply{outcome: "unrecognised", outcome_reason: "unknown_address"} = reply(id)
    end

    test "a retried job never sends a second forward" do
      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id)

      assert :ok = perform_job(ReplyWorker, %{"resend_email_id" => id})
      _first = forwarded()

      assert :ok = perform_job(ReplyWorker, %{"resend_email_id" => id})
      assert_no_email_sent()
    end

    # Security-audit run-1, lead 8: a job queued while the feature was on is
    # discarded, never forwarded, once the feature is parked again.
    test "the parked feature runs no queued forward" do
      original = Application.get_env(:dhc, IntakeReplies)

      Application.put_env(:dhc, IntakeReplies, enabled: false)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:dhc, IntakeReplies),
          else: Application.put_env(:dhc, IntakeReplies, original)
      end)

      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id)

      assert {:discard, :feature_disabled} =
               perform_job(ReplyWorker, %{"resend_email_id" => id})

      assert_no_email_sent()
    end

    test "records the sent id the provider returns" do
      original = Application.get_env(:dhc, Mailer)

      Application.put_env(:dhc, Mailer,
        adapter: Dhc.Email.AdapterStub,
        stub_result: {:ok, %{id: "sent-123"}}
      )

      on_exit(fn -> Application.put_env(:dhc, Mailer, original) end)

      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id)

      assert {:ok, :forwarded} = IntakeReplies.forward(id)
      assert %IntakeReply{forward_sent_id: "sent-123"} = reply(id)
    end

    test "attaches the original as .eml when an attachment cannot be downloaded" do
      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)

      ResendReceivingStub.stub(id,
        attachments: [{%{"filename" => "photo.jpg"}, "jpeg"}],
        raw: "raw message",
        fail: [:download]
      )

      assert {:ok, :forwarded} = IntakeReplies.forward(id)
      email = forwarded()

      assert [
               %{
                 filename: "forwarded_message.eml",
                 content_type: "message/rfc822",
                 data: "raw message"
               }
             ] =
               email.attachments

      assert email.html_body =~ "original message is attached"
      assert email.subject == "[Needs you] Re: Your workshop place"
    end

    test "attaches the original as .eml when the rebuilt reply would be too large" do
      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id, attachments: [{%{"size" => 50_000_000}, "x"}], raw: "raw")

      assert {:ok, :forwarded} = IntakeReplies.forward(id)
      assert [%{filename: "forwarded_message.eml"}] = forwarded().attachments
    end

    test "sends the banner alone when even the original is too large" do
      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)

      ResendReceivingStub.stub(id,
        attachments: [{%{}, String.duplicate("x", 200)}],
        raw: String.duplicate("y", 200)
      )

      assert {:ok, :forwarded} = IntakeReplies.forward(id, max_bytes: 100)
      email = forwarded()
      assert email.attachments == []
      assert email.html_body =~ "kept in Resend for 30 days (received email #{id})"
    end

    test "retries while the reply cannot be read, then forwards the banner alone" do
      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id, fail: [:email])

      assert {:error, {:http_status, 500}} =
               perform_job(ReplyWorker, %{"resend_email_id" => id}, attempt: 1)

      assert_no_email_sent()
      assert %IntakeReply{outcome: "pending"} = reply(id)

      assert :ok = perform_job(ReplyWorker, %{"resend_email_id" => id}, attempt: 5)
      email = forwarded()
      assert email.subject == "[Needs you] (no subject)"
      assert email.html_body =~ "could not be forwarded in full"

      assert %IntakeReply{outcome: "needs_you", outcome_reason: "retries_exhausted"} = reply(id)
    end

    test "alerts the coordinators when the last attempt cannot send the forward" do
      coordinator = staff_fixture("beginners_coordinator")
      original = Application.get_env(:dhc, Mailer)

      Application.put_env(:dhc, Mailer,
        adapter: Dhc.Email.AdapterStub,
        stub_result: {:error, {500, %{"message" => "down"}}}
      )

      on_exit(fn -> Application.put_env(:dhc, Mailer, original) end)

      {_person, address} = person_with_address()
      id = resend_id()
      receive!(id, address)
      ResendReceivingStub.stub(id)

      assert {:error, :forward_failed} =
               perform_job(ReplyWorker, %{"resend_email_id" => id}, attempt: 1)

      assert :ok = perform_job(ReplyWorker, %{"resend_email_id" => id}, attempt: 5)

      key = "beginners-intake-reply:#{id}:forward-failed"

      assert [%Notification{body: body}] =
               Repo.all(
                 from(n in Notification,
                   where: n.principal_id == ^coordinator and n.notification_key == ^key
                 )
               )

      assert body =~ "waiting in Resend"

      assert %IntakeReply{
               outcome: "needs_you",
               outcome_reason: "forward_failed",
               forwarded_at: nil
             } =
               reply(id)

      # A repeat finds the alert already raised.
      assert {:ok, %{outcome: :alerted}} =
               BeginnersWorkshops.execute(:system, {:alert_reply_waiting, id})

      assert Repo.aggregate(from(n in Notification, where: n.notification_key == ^key), :count) ==
               length(
                 Dhc.Auth.Capabilities.principal_ids_with(:"beginners.workshops.alerts.receive")
               )
    end

    test "counts a text-only reply's HTML copy towards the size limit" do
      text = String.duplicate("<", 30)

      assert Forward.rebuilt_bytes(%{"html" => nil, "text" => text}, []) ==
               byte_size(text) + byte_size(String.duplicate("&lt;", 30))
    end

    test "every Intake Email type has a staff label and plain words for the classifier" do
      for type <- Dhc.BeginnersWorkshops.IntakeEmails.EmailType.all() do
        assert is_binary(type.label) and type.label != ""
        assert is_binary(type.description) and type.description != ""
      end
    end
  end

  test "the person's hard delete removes their Intake Replies" do
    coordinator = staff_fixture()
    {person, address} = person_with_address()
    id = resend_id()
    receive!(id, address)

    assert {:ok, %{outcome: :deleted}} =
             BeginnersWorkshops.execute({:staff, coordinator}, {:delete_person, person.id, %{}})

    refute Repo.get_by(IntakeReply, resend_email_id: id)
  end

  test "only the :system actor raises the reply alert" do
    coordinator = staff_fixture()

    assert {:error, :forbidden} =
             BeginnersWorkshops.execute(
               {:staff, coordinator},
               {:alert_reply_waiting, resend_id()}
             )
  end
end
