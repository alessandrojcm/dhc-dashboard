defmodule Dhc.BeginnersWorkshops.IntakeCommandsConcurrencyTest do
  @moduledoc """
  ALE-386: `decline` racing `complete_payment` on real connections outside
  the SQL sandbox (`Dhc.ConcurrencyHelpers`), because a sandboxed connection
  serializes everything and cannot show a lock bug. Stripe is stubbed at the
  HTTP seam; the racing Tasks reach the stub through `$callers`.

  The coordinator declines while the person's Checkout completes. Both queue
  behind the Beginners' Workshop lock with the decline first, so the decline
  wins: the hold becomes `releasing`, the completion that lands after it is
  recorded `paid` and refunded in full at once, and the Intake stays
  `declined` — the automatic refund path, with one email of each kind.
  """

  use Dhc.DataCase, async: false

  import Dhc.BeginnersWorkshopFixtures
  import Dhc.ConcurrencyHelpers

  alias Dhc.Auth.{Principal, UserRole}
  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakeLink,
    IntakePayment,
    IntakeRefund,
    LockTrace,
    WorkshopPolicy
  }

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @workshop_lock "SELECT id FROM beginners_workshops WHERE id = $1 FOR UPDATE"

  defp execute(actor, command),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(@now))

  test "a decline that wins the race takes the automatic refund path for the completion" do
    committed(fn %{workshop: workshop, intake: intake, token: token, coordinator: coordinator} ->
      Stripe.stub_create()
      assert {:ok, _} = execute({:intake_link, token}, :start_payment)
      payment = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))
      session = Stripe.session(payment)

      parent = self()
      holder = Task.async(fn -> hold_row_lock(@workshop_lock, [dump(workshop.id)], parent) end)
      assert_receive :locked, 5_000

      decline =
        Task.async(fn ->
          outside_sandbox(fn ->
            execute(
              {:staff, coordinator},
              {:decline, workshop.id, intake.id, %{"note" => "Can't make it"}}
            )
          end)
        end)

      :ok = wait_for_lock_waiters(1)

      complete =
        Task.async(fn ->
          outside_sandbox(fn -> execute(:stripe, {:complete_payment, session}) end)
        end)

      :ok = wait_for_lock_waiters(2)
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 5_000)

      assert {:ok, %{outcome: :done, state: "declined"}} = Task.await(decline, :infinity)
      assert {:ok, %{outcome: :paid_after_close}} = Task.await(complete, :infinity)

      assert %Intake{state: "declined"} = Repo.reload!(intake)
      assert %IntakePayment{status: "paid"} = Repo.reload!(payment)

      assert [%IntakeRefund{reason: "paid_after_close", amount_cents: 4000, status: "pending"}] =
               Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id))

      assert intake.id |> logged_types() |> Enum.sort() == ~w(declined payment_refunded)

      assert %WaitlistEntry{status: "waiting"} = Repo.get!(WaitlistEntry, intake.waitlist_id)
    end)
  end

  test "decline locks top-down and writes only inside its transaction" do
    committed(fn %{workshop: workshop, intake: intake, token: token, coordinator: coordinator} ->
      Stripe.stub_create()
      assert {:ok, _} = execute({:intake_link, token}, :start_payment)

      {_, events} =
        LockTrace.trace(fn ->
          {:ok, %{outcome: :done}} =
            execute({:staff, coordinator}, {:decline, workshop.id, intake.id, %{}})
        end)

      assert LockTrace.upward_locks(events) == []
      assert LockTrace.writes_outside_transaction(events) == []

      assert LockTrace.transactions(events) == [
               ~w(beginners_workshops waitlist beginners_workshop_intakes beginners_workshop_intake_payments)
             ]
    end)
  end

  defp logged_types(intake_id),
    do:
      Repo.all(
        from(l in IntakeEmailLog,
          where: l.intake_id == ^intake_id and l.occasion != "contact",
          select: l.email_type
        )
      )

  defp dump(id), do: Ecto.UUID.dump!(id)

  # Blocks inside Postgres until at least `count` other backends wait on an
  # ungranted lock.
  defp wait_for_lock_waiters(count) do
    Repo.query!(
      """
      DO $$
      DECLARE attempts int := 0;
      BEGIN
        LOOP
          EXIT WHEN (
            SELECT count(DISTINCT blocked.pid)
            FROM pg_locks blocked
            WHERE NOT blocked.granted AND blocked.pid <> pg_backend_pid()
          ) >= #{count};
          attempts := attempts + 1;
          IF attempts > 500 THEN
            RAISE EXCEPTION 'fewer than #{count} backends queued behind the held lock';
          END IF;
          PERFORM pg_sleep(0.01);
          PERFORM pg_stat_clear_snapshot();
        END LOOP;
      END
      $$
      """,
      []
    )

    :ok
  end

  # One workshop with one contacted (fast-track) Intake and a coordinator,
  # committed outside the sandbox and deleted afterwards.
  defp committed(fun) do
    ctx =
      outside_sandbox(fn ->
        workshop =
          %{
            venue: "Race Hall",
            date: ~D[2026-11-14],
            start_time: ~T[18:30:00],
            capacity: 4,
            fee_cents: 4000,
            payment_cutoff: ~U[2026-11-11 18:30:00.000000Z],
            contact_from: ~D[2026-10-20],
            payment_window_days: WorkshopPolicy.default_payment_window_days()
          }
          |> BeginnersWorkshop.schedule_changeset()
          |> Repo.insert!()

        [person] = waiting_people_fixture(1)
        id = Ecto.UUID.generate()

        intake =
          %{
            id: id,
            workshop_id: workshop.id,
            waitlist_id: person.id,
            origin: "fast_track",
            queue_date: person.initial_registration_date,
            link_token_hash: IntakeLink.hash(IntakeLink.token(id, 1)),
            contacted_at: @now
          }
          |> Intake.contact_changeset()
          |> Repo.insert!()

        %{
          workshop: workshop,
          person: person,
          intake: intake,
          token: IntakeLink.token(id, 1),
          coordinator: staff_fixture("beginners_coordinator")
        }
      end)

    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    outside_sandbox(fn -> fun.(ctx) end)
  end

  defp cleanup!(%{workshop: workshop, person: person, intake: intake, coordinator: coordinator}) do
    refund_ids =
      Repo.all(from(r in IntakeRefund, where: r.intake_id == ^intake.id, select: r.id))

    Repo.delete_all(
      from(j in Oban.Job,
        where:
          fragment("?->>'refund_id'", j.args) in ^refund_ids or
            fragment("?->>'email'", j.args) == ^person.email
      )
    )

    Repo.delete_all(from(r in IntakeRefund, where: r.intake_id == ^intake.id))
    Repo.delete_all(from(p in IntakePayment, where: p.intake_id == ^intake.id))
    Repo.delete_all(from(e in IntakeEvent, where: e.intake_id == ^intake.id))
    Repo.delete_all(from(l in IntakeEmailLog, where: l.intake_id == ^intake.id))
    Repo.delete_all(from(i in Intake, where: i.id == ^intake.id))
    Repo.delete_all(from(w in BeginnersWorkshop, where: w.id == ^workshop.id))
    Repo.delete_all(from(p in UserProfile, where: p.waitlist_id == ^person.id))
    Repo.delete_all(from(e in WaitlistEntry, where: e.id == ^person.id))
    Repo.delete_all(from(r in UserRole, where: r.principal_id == ^coordinator))
    Repo.delete_all(from(m in MemberProfile, where: m.id == ^coordinator))
    Repo.delete_all(from(p in UserProfile, where: p.principal_id == ^coordinator))
    Repo.delete_all(from(p in Principal, where: p.id == ^coordinator))
  end
end
