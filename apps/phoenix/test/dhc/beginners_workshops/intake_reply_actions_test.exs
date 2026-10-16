defmodule Dhc.BeginnersWorkshops.IntakeReplyActionsTest do
  @moduledoc """
  ALE-411: Reply Actions at job level (`IntakeReplies.forward/2`, the
  `ReplyWorker`'s body) and through `Dhc.BeginnersWorkshops.execute/3` as
  `{:intake_reply, id}` — every row of the table, the gates before Jev
  (unrecognised, automated, sender mismatch, empty text), the gates after it
  (disabled, below threshold, unclear money), an old email whose Intake is
  no longer open, a boundary refusal, a Jev failure, and the actor's
  authorization.

  Resend is stubbed with `Dhc.ResendReceivingStub`, TypeSafe with
  `Dhc.TypeSafeStub`, Stripe with `Dhc.BeginnersIntakeStripe`.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Swoosh.TestAssertions
  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakePayment,
    IntakeRefund,
    IntakeReplies,
    IntakeReply,
    WorkshopConsole
  }

  alias Dhc.BeginnersWorkshops.IntakeReplies.ReplyActions
  alias Dhc.BeginnersWorkshops.Workers.ReplyWorker
  alias Dhc.Repo
  alias Dhc.ResendReceivingStub
  alias Dhc.TypeSafeStub
  alias Dhc.Waitlist.WaitlistEntry

  @domain "reply.example.test"
  @now ~U[2026-10-22 12:00:00.000000Z]

  # Every intent on at 0.8; money back is yes at 0.7 and no at 0.3.
  @all_on [
    intents: Map.new(ReplyActions.intents(), &{&1, [enabled: true, threshold: 0.8]}),
    money_back: [yes: 0.7, no: 0.3]
  ]

  setup do
    original_domain = Application.get_env(:dhc, :intake_reply_domain)
    original_actions = Application.get_env(:dhc, ReplyActions)
    Application.put_env(:dhc, :intake_reply_domain, @domain)
    Application.put_env(:dhc, ReplyActions, @all_on)

    on_exit(fn ->
      restore(:intake_reply_domain, original_domain)
      restore(ReplyActions, original_actions)
    end)

    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp restore(key, nil), do: Application.delete_env(:dhc, key)
  defp restore(key, value), do: Application.put_env(:dhc, key, value)

  defp execute(actor, command),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(@now))

  # ── Fixtures ────────────────────────────────────────────────────

  defp contacted!(c) do
    {workshop, [{intake, token}]} = contacted_fixture(c, 1)
    %{workshop: workshop, intake: intake, token: token, person: person(intake)}
  end

  defp paid!(c) do
    %{intake: intake, token: token} = state = contacted!(c)
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token}, :start_payment)

    payment =
      Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))

    assert {:ok, %{outcome: :paid}} =
             execute(:stripe, {:complete_payment, Stripe.session(payment)})

    %{state | intake: Repo.reload!(intake)}
  end

  # A waiting person whose Stripe-paid Intake was deferred: a `held` fee.
  defp fee_holder!(c) do
    %{workshop: workshop, intake: intake} = state = paid!(c)

    assert {:ok, %{state: "deferred"}} =
             execute({:staff, c}, {:defer, workshop.id, intake.id, %{}})

    %{state | intake: Repo.reload!(intake), person: Repo.reload!(state.person)}
  end

  defp person(intake), do: Repo.get!(WaitlistEntry, intake.waitlist_id)

  # A person removed at `removed_at` (through the one standing seam).
  defp removed_person!(removed_at) do
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

    {:ok, {:ok, removed}} =
      Repo.transaction(fn ->
        Dhc.Waitlist.change_standing(person.id, "removed", now: removed_at)
      end)

    removed
  end

  # The "Back on the Waitlist" emails queued for `person`.
  defp back_on_waitlist_emails(person) do
    subject = Repo.get!(Dhc.BeginnersWorkshops.IntakeEmails.Template, "back_on_waitlist").subject

    Enum.filter(
      all_enqueued(worker: Dhc.Email.Worker),
      &(&1.args["email"] == person.email and &1.args["subject"] == subject)
    )
  end

  # ── Replies ─────────────────────────────────────────────────────

  # A reply from the person (or `from:`) to an email about `intake`
  # (`nil`: a Waitlist-tab notice), recorded as the webhook would.
  defp reply!(person, intake, email_type, text, opts \\ []) do
    {:ok, address} = IntakeReplies.reply_to(person, intake && intake.id, email_type)
    id = Ecto.UUID.generate()
    {:ok, :recorded} = IntakeReplies.record_received(%{"email_id" => id, "to" => [address]})

    ResendReceivingStub.stub(id,
      email:
        Map.merge(
          %{
            "from" => Keyword.get(opts, :from, "Person <#{String.upcase(person.email)}>"),
            "text" => text,
            "html" => nil,
            "headers" => Keyword.get(opts, :headers, %{"from" => "Person <#{person.email}>"})
          },
          Keyword.get(opts, :email, %{})
        )
    )

    id
  end

  # Jev answers `intent`; each request is sent to the test.
  defp jev(intent, confidence \\ 0.95, money_back \\ 0.0) do
    test = self()

    Req.Test.stub(Dhc.TypeSafe, fn conn ->
      {request, conn} = TypeSafeStub.request(conn)
      send(test, {:jev, request})
      Req.Test.json(conn, TypeSafeStub.answer(request, intent, confidence, money_back))
    end)
  end

  defp jev_down do
    test = self()

    Req.Test.stub(Dhc.TypeSafe, fn conn ->
      send(test, {:jev, :down})
      Plug.Conn.send_resp(conn, 500, ~s({"error":"down"}))
    end)
  end

  defp offered do
    assert_received {:jev, request}
    request |> get_in(["questions", "intent", "criteria"]) |> Map.keys() |> Enum.sort()
  end

  defp forward!(id, opts \\ []) do
    assert {:ok, :forwarded} =
             IntakeReplies.forward(id, Keyword.put(opts, :clock, Clock.fixed(@now)))

    assert_email_sent(fn email ->
      send(self(), {:forwarded, email})
      true
    end)

    assert_receive {:forwarded, email}
    email
  end

  defp row(id), do: Repo.get_by!(IntakeReply, resend_email_id: id)

  defp events(intake), do: Repo.all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))

  defp notices(intake),
    do:
      Repo.all(
        from(l in IntakeEmailLog,
          where: l.intake_id == ^intake.id,
          order_by: [l.queued_at, l.id],
          select: l.email_type
        )
      )

  # ── The table ───────────────────────────────────────────────────

  describe "can't make this date" do
    test "a contacted person is declined; the history names the reply", %{coordinator: c} do
      %{intake: intake, person: person, workshop: workshop} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "Sorry, I can't make that date.")
      jev("cant_make_date", 0.95, 0.1)

      email = forward!(id)
      assert email.subject == "[Done: Declined] Re: Your workshop place"
      assert email.html_body =~ "Done by email reply: their workshop place was declined."

      assert offered() == ~w(cant_make_date leaving_waitlist link_problem something_else)
      assert %Intake{state: "declined"} = Repo.reload!(intake)

      reply = row(id)

      assert %IntakeReply{
               outcome: "done",
               outcome_reason: nil,
               command: "decline",
               intent: "cant_make_date",
               model: "jev-1.13.0"
             } = reply

      assert_in_delta reply.intent_confidence, 0.95, 1.0e-9
      assert_in_delta reply.money_back, 0.1, 1.0e-9
      assert %{"cant_make_date" => _} = reply.intent_probabilities

      assert [%IntakeEvent{command: "decline", actor_principal_id: nil} = event] = events(intake)
      assert event.intake_reply_id == reply.id

      {:ok, console} = WorkshopConsole.show(workshop.id, Clock.fixed(@now))
      row = console.roster |> Map.values() |> List.flatten() |> Enum.find(&(&1.id == intake.id))
      assert [%{command: "decline", actor: nil, by_email_reply: true}] = row.history
    end

    test "a paid person asking for their money back is cancelled with refund", %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)
      id = reply!(person, intake, "place_confirmed_paid", "Can't come, please refund me.")
      jev("cant_make_date", 0.95, 0.9)

      assert forward!(id).subject =~ "[Done: Cancelled with refund]"
      assert %Intake{state: "cancelled_refunded"} = Repo.reload!(intake)

      assert [%IntakeRefund{reason: "cancelled_with_refund", requested_by_principal_id: nil}] =
               Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id))
    end

    test "a paid person who does not ask for money back is deferred", %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)
      id = reply!(person, intake, "place_confirmed_paid", "Can't come that day.")
      jev("cant_make_date", 0.95, 0.1)

      assert forward!(id).subject =~ "[Done: Moved to a later workshop]"
      assert %Intake{state: "deferred"} = Repo.reload!(intake)
      assert [%CarriedFee{status: "held"}] = fees(person)
    end

    test "unclear money on a paid person is a Deferral", %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)

      id =
        reply!(person, intake, "place_confirmed_paid", "Can't come that day, not sure what now.")

      jev("cant_make_date", 0.95, 0.5)

      assert forward!(id).subject =~ "[Done: Moved to a later workshop]"
      assert %Intake{state: "deferred"} = Repo.reload!(intake)
      assert Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id)) == []
    end
  end

  describe "leaving the Waitlist" do
    test "a contacted person is withdrawn", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "Please take me off the list.")
      jev("leaving_waitlist")

      assert forward!(id).subject =~ "[Done: Withdrawn]"
      assert %Intake{state: "declined"} = Repo.reload!(intake)
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert [%IntakeEvent{command: "withdraw", intake_reply_id: reply_id}] = events(intake)
      assert reply_id == row(id).id
    end

    test "a paid person asking for their money back is withdrawn with the refund",
         %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)
      id = reply!(person, intake, "pre_workshop", "Remove me and refund me please.")
      jev("leaving_waitlist", 0.95, 0.9)

      assert forward!(id).subject =~ "[Done: Withdrawn]"
      assert %Intake{state: "withdrawn"} = Repo.reload!(intake)
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)

      assert [%IntakeRefund{reason: "withdrawn"}] =
               Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id))
    end

    test "unclear money on a paid person needs the coordinator", %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)
      id = reply!(person, intake, "pre_workshop", "I think I want to leave.")
      jev("leaving_waitlist", 0.95, 0.5)

      email = forward!(id)
      assert email.subject =~ "[Needs you]"
      assert email.html_body =~ "not clear whether they want their money back"
      assert %Intake{state: "paid"} = Repo.reload!(intake)
      assert %IntakeReply{outcome: "needs_you", outcome_reason: "money_unclear"} = row(id)
    end

    test "a paid person who does not ask for their money back needs the coordinator",
         %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)
      id = reply!(person, intake, "pre_workshop", "Take me off the list.")
      jev("leaving_waitlist", 0.95, 0.1)

      assert forward!(id).subject =~ "[Needs you]"
      assert %IntakeReply{command: nil, outcome_reason: "money_not_asked"} = row(id)
      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end

    test "a Carried Fee holder asking for their money back is withdrawn with its refund",
         %{coordinator: c} do
      %{person: person} = fee_holder!(c)
      id = reply!(person, nil, "deferred", "Please remove me and refund my fee.")
      jev("leaving_waitlist", 0.95, 0.9)

      assert forward!(id).subject =~ "[Done: Withdrawn]"
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert [%CarriedFee{status: "refunded"}] = fees(person)
    end

    test "unclear money on a Carried Fee holder needs the coordinator", %{coordinator: c} do
      %{person: person} = fee_holder!(c)
      id = reply!(person, nil, "deferred", "I'd like to leave.")
      jev("leaving_waitlist", 0.95, 0.5)

      assert forward!(id).subject =~ "[Needs you]"
      assert %IntakeReply{outcome_reason: "money_unclear"} = row(id)
      assert [%CarriedFee{status: "held"}] = fees(person)
      assert %WaitlistEntry{status: "waiting"} = Repo.reload!(person)
    end

    test "someone with no open Intake is withdrawn", %{coordinator: _c} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      id = reply!(person, nil, "cancelled_unpaid", "Please take me off the Waitlist.")
      jev("leaving_waitlist")

      assert forward!(id).subject =~ "[Done: Withdrawn]"
      assert offered() == ~w(leaving_waitlist something_else)
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
    end
  end

  describe "wants a refund" do
    test "a paid person is cancelled with refund", %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)
      id = reply!(person, intake, "place_confirmed_paid", "Can I have a refund?")
      jev("wants_refund")

      assert forward!(id).subject =~ "[Done: Cancelled with refund]"
      assert %Intake{state: "cancelled_refunded"} = Repo.reload!(intake)
    end

    test "a Carried Fee holder's fee is refunded", %{coordinator: c} do
      %{person: person} = fee_holder!(c)
      id = reply!(person, nil, "deferred", "Could I get my money back instead?")
      jev("wants_refund")

      assert forward!(id).subject =~ "[Done: Credit refunded]"
      assert offered() == ~w(leaving_waitlist something_else wants_refund)
      assert [%CarriedFee{status: "refunded"}] = fees(person)
      assert %WaitlistEntry{status: "waiting"} = Repo.reload!(person)
    end

    test "a boundary refusal forwards [Needs you] with the reason", %{coordinator: _c} do
      # An imported fee not yet linked to its Stripe payment cannot be
      # refunded through Stripe: the locked re-check refuses it.
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      assert {:ok, _} = execute(:system, {:import_carried_fee, person.id, "Paid 2025"})
      id = reply!(person, nil, "cancelled_unpaid", "Please refund my fee.")
      jev("wants_refund")

      email = forward!(id)
      assert email.subject =~ "[Needs you]"
      assert email.html_body =~ "could not be run"

      assert %IntakeReply{
               outcome: "refused",
               outcome_reason: "payment_not_linked",
               command: "refund_carried_fee"
             } = row(id)

      assert [%CarriedFee{status: "held"}] = fees(person)
    end
  end

  describe "wants to come back (ALE-412)" do
    test "a removed person within retention is restored and told once", %{coordinator: _c} do
      person = removed_person!(~U[2026-09-01 12:00:00Z])
      id = reply!(person, nil, "withdrawn_forfeited", "Could I come back onto the waitlist?")
      jev("wants_to_come_back")

      email = forward!(id)
      assert email.subject =~ "[Done: Restored]"
      assert email.html_body =~ "Done by email reply: they were put back on the Waitlist"
      assert offered() == ~w(something_else wants_to_come_back)

      assert %IntakeReply{outcome: "done", command: "restore_person"} = row(id)

      restored = Repo.reload!(person)
      assert %WaitlistEntry{status: "waiting", removed_at: nil} = restored
      # Original priority: the queue position is the first registration.
      assert restored.initial_registration_date == person.initial_registration_date
      assert [_one] = back_on_waitlist_emails(person)
    end

    test "someone past retention needs the coordinator and Jev is not called" do
      person = removed_person!(~U[2026-07-01 12:00:00Z])
      id = reply!(person, nil, "withdrawn_forfeited", "Could I come back onto the waitlist?")
      jev("wants_to_come_back")

      assert forward!(id).subject =~ "[Needs you]"
      refute_received {:jev, _request}
      assert %IntakeReply{outcome: "needs_you", outcome_reason: "no_reply_action"} = row(id)
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert back_on_waitlist_emails(person) == []
    end

    test "a retried job finds the restore committed and does not run it again" do
      person = removed_person!(~U[2026-09-01 12:00:00Z])
      id = reply!(person, nil, "withdrawn_forfeited", "Could I come back onto the waitlist?")
      jev("wants_to_come_back")
      _forward = forward!(id)
      assert_received {:jev, _first_request}
      assert %IntakeReply{action_committed_at: %DateTime{}} = row(id)

      # As if the job crashed after the restore committed: no Intake history
      # row names the reply, and the person is already waiting.
      Repo.update_all(from(r in IntakeReply, where: r.resend_email_id == ^id),
        set: [outcome: "pending", outcome_reason: nil, decided_at: nil, forwarded_at: nil]
      )

      assert forward!(id).subject =~ "[Done: Restored]"
      assert %IntakeReply{outcome: "done", outcome_reason: nil} = row(id)
      assert [_one] = back_on_waitlist_emails(person)
      refute_received {:jev, _second_request}
    end
  end

  describe "restore_person through execute/3 (ALE-412)" do
    setup do
      person = removed_person!(~U[2026-09-01 12:00:00Z])
      id = reply!(person, nil, "withdrawn_forfeited", "Hello")
      %{person: person, actor: {:intake_reply, row(id).id}}
    end

    test "restores within retention and emails the person once", %{person: person, actor: actor} do
      assert {:ok, %{waitlist_id: waitlist_id, status: "waiting", outcome: :done}} =
               execute(actor, {:restore_person, person.id})

      assert waitlist_id == person.id

      assert [%{args: %{"email" => email, "data_variables" => %{"MESSAGE_HTML" => html}}}] =
               back_on_waitlist_emails(person)

      assert email == person.email
      assert html =~ "back on the waitlist"

      # A second request finds them waiting: refused, and nobody is emailed again.
      assert {:error, :not_restorable} = execute(actor, {:restore_person, person.id})
      assert [_one] = back_on_waitlist_emails(person)
    end

    test "a person who comes back twice is told twice", %{person: person, actor: actor} do
      assert {:ok, %{outcome: :done}} = execute(actor, {:restore_person, person.id})

      {:ok, _} =
        Repo.transaction(fn ->
          Dhc.Waitlist.change_standing(person.id, "removed", now: ~U[2026-10-01 12:00:00Z])
        end)

      assert {:ok, %{outcome: :done}} = execute(actor, {:restore_person, person.id})
      assert [_first, _second] = back_on_waitlist_emails(person)
    end

    test "refuses someone past retention", %{actor: actor} do
      person = removed_person!(~U[2026-07-01 12:00:00Z])

      assert {:error, :not_restorable} = execute(actor, {:restore_person, person.id})
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert back_on_waitlist_emails(person) == []
    end

    test "refuses someone who is not removed", %{actor: actor} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

      assert {:error, :not_restorable} = execute(actor, {:restore_person, person.id})
      assert back_on_waitlist_emails(person) == []
    end

    test "refuses a removed person whose Intake is still open",
         %{coordinator: c, actor: actor} do
      %{person: person} = contacted!(c)

      {:ok, _} =
        Repo.transaction(fn ->
          Dhc.Waitlist.change_standing(person.id, "removed", now: ~U[2026-10-20 12:00:00Z])
        end)

      assert {:error, :open_intake} = execute(actor, {:restore_person, person.id})
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
      assert back_on_waitlist_emails(person) == []
    end

    test "refuses an unknown person", %{actor: actor} do
      assert {:error, :person_not_found} = execute(actor, {:restore_person, Ecto.UUID.generate()})
    end

    test "only an Intake Reply may run it", %{person: person, coordinator: c} do
      assert {:error, :unknown_command} = execute({:staff, c}, {:restore_person, person.id})
      assert {:error, :unknown_command} = execute(:system, {:restore_person, person.id})

      assert {:error, :forbidden} =
               execute({:intake_reply, Ecto.UUID.generate()}, {:restore_person, person.id})

      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
    end
  end

  describe "lost or broken link" do
    test "a contacted person's link is sent again", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)
      before = notices(intake)
      id = reply!(person, intake, "contact_pay", "The link doesn't work for me.")
      jev("link_problem")

      assert forward!(id).subject =~ "[Done: Link resent]"
      assert notices(intake) == before ++ ["contact_pay"]
    end

    test "a paid person's link is sent again", %{coordinator: c} do
      %{intake: intake, person: person} = paid!(c)
      before = notices(intake)
      id = reply!(person, intake, "place_confirmed_paid", "I lost my link.")
      jev("link_problem")

      assert forward!(id).subject =~ "[Done: Link resent]"
      assert notices(intake) == before ++ ["place_confirmed_paid"]
    end

    test "a retried job finds the history row and does not resend", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "The link doesn't work for me.")
      jev("link_problem")
      _forward = forward!(id)
      assert_received {:jev, _first_request}
      sent = notices(intake)

      # As if the job crashed after the Reply Action committed.
      Repo.update_all(from(r in IntakeReply, where: r.resend_email_id == ^id),
        set: [outcome: "pending", decided_at: nil, forwarded_at: nil]
      )

      assert forward!(id).subject =~ "[Done: Link resent]"
      assert notices(intake) == sent
      refute_received {:jev, _second_request}
    end
  end

  # ── Gates ───────────────────────────────────────────────────────

  describe "before Jev" do
    test "a reply from another address needs the coordinator", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)

      id =
        reply!(person, intake, "contact_pay", "I can't make it.",
          from: "Someone <other@example.com>"
        )

      jev("cant_make_date")

      email = forward!(id)
      assert email.subject =~ "[Needs you]"
      assert email.html_body =~ "different address"
      assert %IntakeReply{outcome: "needs_you", outcome_reason: "sender_mismatch"} = row(id)
      refute_received {:jev, _request}
      assert %Intake{state: "contacted"} = Repo.reload!(intake)
    end

    test "automated mail is [Auto-reply] and Jev is not called", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)

      for headers <- [
            %{"Auto-Submitted" => "auto-replied"},
            %{"x-autoreply" => "yes"},
            %{"precedence" => "bulk"},
            %{"precedence" => ["junk"]}
          ] do
        id = reply!(person, intake, "contact_pay", "I am out of the office.", headers: headers)
        jev("cant_make_date")

        assert forward!(id).subject =~ "[Auto-reply]"
        assert %IntakeReply{outcome: "automated", outcome_reason: "auto_reply"} = row(id)
        refute_received {:jev, _request}
      end

      # `Auto-Submitted: no` is a person.
      id =
        reply!(person, intake, "contact_pay", "I can't make it.",
          headers: %{"auto-submitted" => "no"}
        )

      jev("cant_make_date")
      assert forward!(id).subject =~ "[Done: Declined]"
    end

    test "a reply with no new text needs the coordinator", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "> quoted only\n> nothing new")
      jev("cant_make_date")

      assert forward!(id).subject =~ "[Needs you]"
      assert %IntakeReply{outcome_reason: "empty_reply"} = row(id)
      refute_received {:jev, _request}
    end

    test "with every offered intent off, no reply text leaves Phoenix", %{coordinator: c} do
      Application.put_env(:dhc, ReplyActions, [])
      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "I can't make it.")
      jev("cant_make_date")

      assert forward!(id).subject =~ "[Needs you]"
      assert %IntakeReply{outcome_reason: "reply_actions_off"} = row(id)
      refute_received {:jev, _request}
    end

    test "an unrecognised address stays [Unrecognised]" do
      id = Ecto.UUID.generate()

      {:ok, :recorded} =
        IntakeReplies.record_received(%{"email_id" => id, "to" => ["nobody@#{@domain}"]})

      ResendReceivingStub.stub(id, email: %{"subject" => "Hello"})
      jev("cant_make_date")

      assert forward!(id).subject == "[Unrecognised] Hello"
      assert %IntakeReply{outcome: "unrecognised", outcome_reason: "unknown_address"} = row(id)
      refute_received {:jev, _request}
    end
  end

  describe "after Jev" do
    test "a disabled intent needs the coordinator", %{coordinator: c} do
      Application.put_env(:dhc, ReplyActions,
        intents: %{"leaving_waitlist" => [enabled: true, threshold: 0.8]}
      )

      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "I can't make it.")
      jev("cant_make_date")

      assert forward!(id).subject =~ "[Needs you]"
      assert %IntakeReply{outcome_reason: "intent_disabled", intent: "cant_make_date"} = row(id)
      assert %Intake{state: "contacted"} = Repo.reload!(intake)
    end

    test "below the threshold needs the coordinator", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "Maybe I can't make it?")
      jev("cant_make_date", 0.6)

      assert forward!(id).subject =~ "[Needs you]"
      assert %IntakeReply{outcome_reason: "below_threshold", command: nil} = row(id)
      assert %Intake{state: "contacted"} = Repo.reload!(intake)
    end

    test "something else needs the coordinator", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "What should I wear?")
      jev("something_else")

      assert forward!(id).subject =~ "[Needs you]"
      assert %IntakeReply{outcome_reason: "something_else"} = row(id)
    end

    test "an old email whose Intake is no longer open acts only on person intents",
         %{coordinator: c} do
      %{intake: intake, person: person, workshop: workshop} = contacted!(c)
      assert {:ok, _} = execute({:staff, c}, {:decline, workshop.id, intake.id, %{}})

      id = reply!(person, intake, "contact_pay", "I can't make that date.")
      jev("something_else")

      assert forward!(id).subject =~ "[Needs you]"
      # "Can't make it" is no longer on offer for this email.
      assert offered() == ~w(leaving_waitlist something_else)
      assert %Intake{state: "declined"} = Repo.reload!(intake)

      # Leaving acts whichever email was answered.
      id = reply!(person, intake, "contact_pay", "Please remove me from the list.")
      jev("leaving_waitlist")
      assert forward!(id).subject =~ "[Done: Withdrawn]"
      assert %WaitlistEntry{status: "removed"} = Repo.reload!(person)
    end

    test "a Jev failure retries with the job, then forwards [Needs you]", %{coordinator: c} do
      %{intake: intake, person: person} = contacted!(c)
      id = reply!(person, intake, "contact_pay", "I can't make it.")
      jev_down()

      assert {:error, :classifier_failed} =
               perform_job(ReplyWorker, %{"resend_email_id" => id}, attempt: 1)

      assert_no_email_sent()
      assert %IntakeReply{outcome: "pending", decided_at: nil} = row(id)

      assert :ok = perform_job(ReplyWorker, %{"resend_email_id" => id}, attempt: 5)

      assert_email_sent(fn email -> email.subject =~ "[Needs you]" end)
      assert %IntakeReply{outcome: "needs_you", outcome_reason: "classifier_failed"} = row(id)
      assert %Intake{state: "contacted"} = Repo.reload!(intake)
    end
  end

  # ── The actor ───────────────────────────────────────────────────

  describe "{:intake_reply, id} through execute/3" do
    setup %{coordinator: c} do
      %{intake: intake, person: person, workshop: workshop} = paid!(c)
      id = reply!(person, intake, "place_confirmed_paid", "Hello")
      %{intake: intake, person: person, workshop: workshop, reply: row(id)}
    end

    test "the locked re-check decides", %{intake: intake, workshop: workshop, reply: reply} do
      assert {:error, :already_paid} =
               execute({:intake_reply, reply.id}, {:decline, workshop.id, intake.id, %{}})

      assert {:ok, %{outcome: :done}} =
               execute({:intake_reply, reply.id}, {:defer, workshop.id, intake.id, %{}})

      assert {:ok, %{outcome: :already_done}} =
               execute({:intake_reply, reply.id}, {:defer, workshop.id, intake.id, %{}})
    end

    test "is authorized for exactly the Reply Action commands",
         %{intake: intake, person: person, workshop: workshop, reply: reply} do
      actor = {:intake_reply, reply.id}

      for command <- [
            {:rotate_link, workshop.id, intake.id, %{}},
            {:confirm, workshop.id, intake.id, %{}},
            {:correct_attendance, workshop.id, intake.id, %{"to" => "attended"}},
            {:forfeit_carried_fee, {:person, person.id}, Ecto.UUID.generate()},
            {:delete_person, person.id, %{"refund" => true}},
            {:cancel_workshop, workshop.id, %{}},
            {:fast_track, workshop.id, {:waitlist_entry, person.id}}
          ],
          do: assert({:error, :forbidden} = execute(actor, command))

      # A Reply Action never forfeits: withdraw only with its refund.
      assert {:error, :forbidden} = execute(actor, {:withdraw, person.id, %{}})
      assert {:error, :forbidden} = execute(actor, {:withdraw, person.id, %{refund: false}})

      assert {:error, :forbidden} =
               execute(actor, {:withdraw, workshop.id, intake.id, %{"refund" => false}})

      # Only a recorded Intake Reply may act.
      assert {:error, :forbidden} =
               execute(
                 {:intake_reply, Ecto.UUID.generate()},
                 {:defer, workshop.id, intake.id, %{}}
               )

      assert {:error, :forbidden} =
               execute({:intake_reply, "not-a-uuid"}, {:defer, workshop.id, intake.id, %{}})

      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end
  end

  defp fees(person), do: Repo.all(from(f in CarriedFee, where: f.waitlist_id == ^person.id))
end
