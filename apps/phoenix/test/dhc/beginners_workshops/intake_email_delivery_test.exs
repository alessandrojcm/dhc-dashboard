defmodule Dhc.BeginnersWorkshops.IntakeEmailDeliveryTest do
  @moduledoc """
  ALE-401: the rules `IntakeEmails.deliver/5` owns — which variant it picks,
  what an occasion already in the ledger means, who has no recipient — and
  that the ledger queries name the same occasions as the constructors.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Swoosh.TestAssertions
  import Dhc.BeginnersWorkshopFixtures
  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, CarriedFee, Clock, Intake, IntakeEmailLog}
  alias Dhc.BeginnersWorkshops.IntakeEmails
  alias Dhc.BeginnersWorkshops.IntakeReplies
  alias Dhc.BeginnersWorkshops.IntakeReplyAddress
  alias Dhc.BeginnersWorkshops.IntakeEmails.Occasion
  alias Dhc.Email.Worker
  alias Dhc.Waitlist.WaitlistEntry

  require Occasion

  @reading Clock.read(Clock.fixed(~U[2026-10-09 11:00:00.000000Z]))

  setup do
    staff = staff_fixture()
    workshop = Repo.get!(BeginnersWorkshop, scheduled_fixture(staff).id)
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z], first_name: "Aoife")
    {intake, _token} = intake_fixture!(workshop.id, person)

    %{workshop: workshop, person: person, intake: intake}
  end

  defp jobs, do: all_enqueued(worker: Worker)
  defp logged(intake), do: Repo.all(from(l in IntakeEmailLog, where: l.intake_id == ^intake.id))

  defp in_transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp with_reply_domain(domain, fun) do
    original = Application.get_env(:dhc, :intake_reply_domain)
    Application.put_env(:dhc, :intake_reply_domain, domain)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:dhc, :intake_reply_domain)
      else
        Application.put_env(:dhc, :intake_reply_domain, original)
      end
    end
  end

  defp with_intake_replies(enabled, fun) do
    original = Application.get_env(:dhc, IntakeReplies)
    Application.put_env(:dhc, IntakeReplies, enabled: enabled)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:dhc, IntakeReplies)
      else
        Application.put_env(:dhc, IntakeReplies, original)
      end
    end
  end

  describe "variants" do
    test "a contacted person is asked to pay, a holder of a held Carried Fee to confirm", ctx do
      assert {:ok, :queued} =
               IntakeEmails.deliver(
                 {:intake, ctx.intake, ctx.workshop},
                 :contact,
                 Occasion.contact(),
                 @reading
               )

      Repo.insert!(%CarriedFee{
        waitlist_id: ctx.person.id,
        status: "held",
        origin: "import",
        imported_paid_text: "Yes",
        status_changed_at: @reading.now
      })

      assert {:ok, :queued} =
               IntakeEmails.deliver(
                 {:intake, ctx.intake, ctx.workshop},
                 :contact,
                 Occasion.resend_link(Ecto.UUID.generate()),
                 @reading
               )

      assert ctx.intake |> logged() |> Enum.map(& &1.email_type) |> Enum.sort() ==
               ["contact_confirm", "contact_pay"]

      assert jobs() |> Enum.map(& &1.args["data_variables"]["BUTTON_LABEL"]) |> Enum.sort() ==
               ["Confirm my place", "Pay for your place"]
    end

    test "Place confirmed follows how the Intake was paid", ctx do
      stripe = force_intake_state!(ctx.intake.id, "paid")

      assert {:ok, :queued} =
               IntakeEmails.deliver(
                 {:intake, stripe, ctx.workshop},
                 :place_confirmed,
                 Occasion.place_confirmed(),
                 @reading
               )

      other = waiting_person_fixture(~U[2025-02-01 12:00:00Z])
      {intake, _token} = intake_fixture!(ctx.workshop.id, other)
      carried = force_carried_fee_paid!(intake)

      assert {:ok, :queued} =
               IntakeEmails.deliver(
                 {:intake, carried, ctx.workshop},
                 :place_confirmed,
                 Occasion.place_confirmed(),
                 @reading
               )

      assert [%{email_type: "place_confirmed_paid"}] = logged(stripe)
      assert [%{email_type: "place_confirmed_carried"}] = logged(carried)
    end

    test "a link travels in the Contact email while contacted, Place confirmed once paid", ctx do
      assert {:ok, :queued} =
               IntakeEmails.deliver(
                 {:intake, ctx.intake, ctx.workshop},
                 :link,
                 Occasion.resend_link("a"),
                 @reading
               )

      paid = force_intake_state!(ctx.intake.id, "paid")

      assert {:ok, :queued} =
               IntakeEmails.deliver(
                 {:intake, paid, ctx.workshop},
                 :link,
                 Occasion.resend_link("b"),
                 @reading
               )

      assert ctx.intake |> logged() |> Map.new(&{&1.occasion, &1.email_type}) == %{
               "resend_link:a" => "contact_pay",
               "resend_link:b" => "place_confirmed_paid"
             }
    end
  end

  describe "an occasion already in the ledger" do
    test "an owed occasion is skipped quietly", ctx do
      paid = force_intake_state!(ctx.intake.id, "paid")
      about = {:intake, paid, ctx.workshop}

      assert {:ok, :queued} =
               IntakeEmails.deliver(about, "pre_workshop", Occasion.pre_workshop(0), @reading)

      assert {:ok, :already_sent} =
               IntakeEmails.deliver(about, "pre_workshop", Occasion.pre_workshop(0), @reading)

      assert [_one] = jobs()
      assert [%{occasion: "pre_workshop"}] = logged(paid)
    end

    test "an event occasion is a concurrent change, and nothing is sent", ctx do
      about = {:intake, ctx.intake, ctx.workshop}

      assert {:ok, :queued} =
               in_transaction(fn ->
                 IntakeEmails.deliver(about, "declined", Occasion.declined(), @reading)
               end)

      assert {:error, :concurrent_change} =
               in_transaction(fn ->
                 IntakeEmails.deliver(about, "declined", Occasion.declined(), @reading)
               end)

      assert [_one] = jobs()
      assert [%{occasion: "declined"}] = logged(ctx.intake)
    end
  end

  describe "no recipient" do
    test "an anonymised Intake is sent nothing", ctx do
      %Intake{} = intake = ctx.intake
      anonymised = %{intake | waitlist_id: nil}

      for {email, occasion} <- [
            {"declined", Occasion.declined()},
            {"follow_up", Occasion.follow_up()}
          ] do
        assert {:ok, :no_recipient} =
                 IntakeEmails.deliver(
                   {:intake, anonymised, ctx.workshop},
                   email,
                   occasion,
                   @reading
                 )
      end

      assert jobs() == []
      assert logged(ctx.intake) == []
    end

    test "a person with no email is sent nothing", ctx do
      %WaitlistEntry{} = person = ctx.person

      assert {:ok, :no_recipient} =
               IntakeEmails.deliver(
                 {:person, %{person | email: nil}, ctx.intake.id},
                 "withdrawn_forfeited",
                 Occasion.withdrawn(Ecto.UUID.generate()),
                 @reading
               )

      assert {:ok, :no_recipient} =
               IntakeEmails.deliver(
                 {:person, nil, nil},
                 "withdrawn_forfeited",
                 Occasion.withdrawn(Ecto.UUID.generate()),
                 @reading
               )

      assert jobs() == []
    end
  end

  test "a person's notice with no Intake to log it on is queued without a ledger row", ctx do
    fee_id = Ecto.UUID.generate()

    assert {:ok, :queued} =
             IntakeEmails.deliver(
               {:person, ctx.person, nil},
               "withdrawn_forfeited",
               Occasion.withdrawn(fee_id),
               @reading
             )

    assert [%{args: %{"email" => email}}] = jobs()
    assert email == ctx.person.email
    assert Repo.all(IntakeEmailLog) == []
  end

  describe "Intake Reply addresses" do
    test "each queued email has a distinct address bound to its entry, type and Intake", ctx do
      with_reply_domain("reply.example.test", fn ->
        assert {:ok, :queued} =
                 IntakeEmails.deliver(
                   {:intake, ctx.intake, ctx.workshop},
                   :contact,
                   Occasion.contact(),
                   @reading
                 )

        assert {:ok, :queued} =
                 IntakeEmails.deliver(
                   {:intake, ctx.intake, ctx.workshop},
                   :link,
                   Occasion.resend_link(Ecto.UUID.generate()),
                   @reading
                 )

        assert [%{args: first_args}, %{args: second_args}] = jobs()

        for args <- [first_args, second_args] do
          assert is_binary(args["sealed_reply_to"])
          refute Map.has_key?(args, "reply_to")
          refute String.contains?(inspect(args), "@reply.example.test")
        end

        first_address = deliver_job_and_capture_reply_to(first_args)
        second_address = deliver_job_and_capture_reply_to(second_args)
        assert first_address != second_address

        for address <- [first_address, second_address] do
          assert address =~ ~r/^[a-z0-9]{32}@reply\.example\.test$/
          assert {:ok, %IntakeReplyAddress{} = binding} = IntakeReplies.resolve(address)
          assert binding.waitlist_entry.id == ctx.person.id
          assert binding.intake.id == ctx.intake.id
          assert binding.email_type == "contact_pay"
          assert byte_size(binding.token_hash) == 32
          [local_part, _domain] = String.split(address, "@")
          refute binding.token_hash == local_part
        end

        [first_local, domain] = String.split(first_address, "@")
        assert {:ok, _binding} = IntakeReplies.resolve("#{String.upcase(first_local)}@#{domain}")
        assert :unknown = IntakeReplies.resolve("#{first_local}@elsewhere.example")
      end)
    end

    test "a Waitlist notice without an Intake is bound to the person only", ctx do
      with_reply_domain("reply.example.test", fn ->
        assert {:ok, :queued} =
                 IntakeEmails.deliver(
                   {:person, ctx.person, nil},
                   "withdrawn_forfeited",
                   Occasion.withdrawn(Ecto.UUID.generate()),
                   @reading
                 )

        assert [%{args: args}] = jobs()
        assert is_binary(args["sealed_reply_to"])
        address = deliver_job_and_capture_reply_to(args)
        assert {:ok, binding} = IntakeReplies.resolve(address)
        assert binding.waitlist_entry.id == ctx.person.id
        assert binding.intake == nil
        assert binding.email_type == "withdrawn_forfeited"
        assert Repo.all(IntakeEmailLog) == []
      end)
    end

    test "the domain being unset keeps the global Reply-To and creates no binding", ctx do
      with_reply_domain(nil, fn ->
        assert {:ok, :queued} =
                 IntakeEmails.deliver(
                   {:intake, ctx.intake, ctx.workshop},
                   :contact,
                   Occasion.contact(),
                   @reading
                 )

        assert [%{args: args}] = jobs()
        refute Map.has_key?(args, "sealed_reply_to")
        assert Repo.all(IntakeReplyAddress) == []

        assert :ok = Worker.perform(%Oban.Job{id: 100, args: args})

        assert_email_sent(fn email ->
          assert email.reply_to == {"", "contact@dublinhemaclub.com"}
        end)
      end)
    end

    test "parked Intake Replies keep the global Reply-To and create no binding", ctx do
      with_reply_domain("reply.example.test", fn ->
        with_intake_replies(false, fn ->
          assert {:ok, :queued} =
                   IntakeEmails.deliver(
                     {:intake, ctx.intake, ctx.workshop},
                     :contact,
                     Occasion.contact(),
                     @reading
                   )

          assert [%{args: args}] = jobs()
          refute Map.has_key?(args, "sealed_reply_to")
          assert Repo.all(IntakeReplyAddress) == []

          assert :ok = Worker.perform(%Oban.Job{id: 101, args: args})

          assert_email_sent(fn email ->
            assert email.reply_to == {"", "contact@dublinhemaclub.com"}
          end)
        end)
      end)
    end

    test "the binding and email job roll back with the caller transaction", ctx do
      with_reply_domain("reply.example.test", fn ->
        assert {:error, :test_rollback} =
                 Repo.transaction(fn ->
                   assert {:ok, :queued} =
                            IntakeEmails.deliver(
                              {:intake, ctx.intake, ctx.workshop},
                              :contact,
                              Occasion.contact(),
                              @reading
                            )

                   Repo.rollback(:test_rollback)
                 end)

        assert Repo.all(IntakeReplyAddress) == []
        assert jobs() == []
      end)
    end
  end

  defp deliver_job_and_capture_reply_to(args) do
    assert :ok = Worker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})

    assert_email_sent(fn email ->
      send(self(), {:reply_to, email.reply_to})
      true
    end)

    assert_receive {:reply_to, {"", address}}
    address
  end

  test "the Pre-workshop info occasion in SQL is the constructor's, for every schedule" do
    sql =
      from(s in fragment("SELECT generate_series(0, 3) AS n"),
        order_by: s.n,
        select: {s.n, Occasion.pre_workshop_sql(s.n)}
      )
      |> Repo.all()

    assert sql == for(n <- 0..3, do: {n, Occasion.pre_workshop(n).name})

    assert Enum.map(sql, &elem(&1, 1)) ==
             ~w(pre_workshop pre_workshop:1 pre_workshop:2 pre_workshop:3)
  end

  test "Pre-workshop info is owed by a paid Intake until logged for this schedule", ctx do
    paid = force_intake_state!(ctx.intake.id, "paid")

    owing = fn ->
      :pre_workshop |> IntakeEmails.owing() |> select([intake: i], i.id) |> Repo.all()
    end

    assert owing.() == [paid.id]

    {:ok, :queued} =
      IntakeEmails.deliver(
        {:intake, paid, ctx.workshop},
        "pre_workshop",
        Occasion.pre_workshop(0),
        @reading
      )

    assert owing.() == []

    ctx.workshop |> Ecto.Changeset.change(reschedule_count: 1) |> Repo.update!()
    assert owing.() == [paid.id]
  end

  test "the console's scheduled emails follow the same occasions", %{workshop: workshop} do
    assert [%{email_type: "pre_workshop", at: at}] = IntakeEmails.scheduled("paid", [], workshop)
    assert at == workshop.payment_cutoff
    assert IntakeEmails.scheduled("paid", ["pre_workshop"], workshop) == []

    rescheduled = %{workshop | reschedule_count: 2}
    assert [_owed] = IntakeEmails.scheduled("paid", ["pre_workshop"], rescheduled)
    assert IntakeEmails.scheduled("paid", ["pre_workshop:2"], rescheduled) == []

    finalised = %{workshop | status: "finalised"}
    assert [%{email_type: "follow_up"}] = IntakeEmails.scheduled("attended", [], finalised)
    assert IntakeEmails.scheduled("attended", ["follow_up"], finalised) == []
    assert IntakeEmails.scheduled("contacted", [], workshop) == []
  end
end
