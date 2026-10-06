defmodule Dhc.Workshops.StripeIdentifierWriteTest do
  @moduledoc """
  ALE-193 (code release): after the ALE-179 expand migration split the
  Stripe identifier into `stripe_payment_intent_id` (`pi_*`) and
  `stripe_checkout_session_id` (`cs_*`), the application must write each
  kind to its own column.

  These tests pin the write behavior at the `Dhc.Workshops` public seam:
  `complete_member_registration/3` writes the PaymentIntent id to
  `stripe_payment_intent_id` and its idempotency lookup uses that column,
  and a completion holding the Workshop lock commits before a concurrent
  deletion decides to archive. Archived-Workshop gating and the external
  refund source live in `Dhc.Workshops.PaymentCommandsTest`.

  Stripe is stubbed at the one Stripe transport seam (`Req.Test` under
  `Dhc.Stripe`, ALE-342), so the live Workshop Stripe adapter and client run
  and only the HTTP hop is faked. Answers are driven by `Application` env so
  a completion running in a spawned Task sees the same Stripe as the test.
  """

  use Dhc.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Dhc.Auth.Principal
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Workshops
  alias Dhc.Workshops.{PaymentAttempt, Registration}
  alias Dhc.StripeHTTPStub
  alias Dhc.WorkshopFixtures

  setup do
    Req.Test.stub(Dhc.Stripe, &stripe/1)

    on_exit(fn ->
      Application.delete_env(:dhc, :workshop_stripe_test_workshop_id)
      Application.delete_env(:dhc, :workshop_stripe_test_member_user_id)
    end)

    :ok
  end

  # ── Member registration writes stripe_payment_intent_id ──────────────

  describe "complete_member_registration/3 writes the split columns" do
    test "writes the PaymentIntent id to stripe_payment_intent_id, not the checkout column" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      pi_id = "pi_member_#{System.unique_integer([:positive])}"

      assert {:ok, %Registration{} = registration} =
               Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert registration.stripe_payment_intent_id == pi_id
      assert registration.stripe_checkout_session_id == nil
    end

    test "idempotency lookup uses stripe_payment_intent_id: replaying the same PI returns the existing row" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      pi_id = "pi_idem_#{System.unique_integer([:positive])}"

      assert {:ok, first} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)
      assert {:ok, second} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert second.id == first.id
    end
  end

  describe "delete and registration serialization" do
    test "a completion holding the Workshop lock commits before deletion decides to archive" do
      {workshop, member} =
        outside_sandbox(fn ->
          workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
          member = WorkshopFixtures.member_fixture()
          {workshop, member}
        end)

      user_id = member.auth_user_id

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      ready_lock = :erlang.phash2({workshop.id, :ready}, 2_000_000_000)
      release_lock = :erlang.phash2({workshop.id, :release}, 2_000_000_000)
      trigger = "test_registration_delay_#{ready_lock}"

      outside_sandbox(fn ->
        install_registration_delay!(trigger, workshop.id, ready_lock, release_lock)
      end)

      on_exit(fn ->
        outside_sandbox(fn ->
          Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON club_activity_registrations")
          Repo.query!("DROP FUNCTION IF EXISTS #{trigger}()")
          Repo.delete_all(from r in Registration, where: r.club_activity_id == ^workshop.id)
          Repo.delete_all(from pa in PaymentAttempt, where: pa.club_activity_id == ^workshop.id)
          Repo.delete_all(from w in Dhc.Workshops.Workshop, where: w.id == ^workshop.id)
          Repo.delete_all(from mp in MemberProfile, where: mp.id == ^member.principal_id)
          Repo.delete_all(from up in UserProfile, where: up.id == ^member.profile_id)
          Repo.delete_all(from p in Principal, where: p.id == ^member.principal_id)
        end)
      end)

      supervisor = start_supervised!(Task.Supervisor)
      payment_intent_id = "pi_delete_race_#{System.unique_integer([:positive])}"
      test_pid = self()

      coordinator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          outside_sandbox(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1)", [release_lock])
              send(test_pid, :release_lock_acquired)

              receive do
                :release_registration -> :ok
              end
            end)
          end)
        end)

      assert_receive :release_lock_acquired

      completion =
        Task.Supervisor.async_nolink(supervisor, fn ->
          outside_sandbox(fn ->
            Workshops.complete_member_registration(workshop.id, user_id, payment_intent_id)
          end)
        end)

      outside_sandbox(fn -> await_advisory_lock!(ready_lock, 1_000) end)

      deletion =
        Task.Supervisor.async_nolink(supervisor, fn ->
          outside_sandbox(fn -> Workshops.delete_workshop(workshop.id) end)
        end)

      outside_sandbox(fn -> await_workshop_lock_wait!(1_000) end)
      send(coordinator.pid, :release_registration)

      assert {:ok, %Registration{stripe_payment_intent_id: ^payment_intent_id}} =
               Task.await(completion, :infinity)

      assert {:ok, :archived, _summary} = Task.await(deletion, :infinity)
      assert {:ok, :ok} = Task.await(coordinator, :infinity)
    end
  end

  # ── Stripe HTTP fake ─────────────────────────────────────────────────

  defp stripe(conn), do: stripe(conn.method, conn.request_path, conn)

  defp stripe("POST", "/v1/payment_intents", conn) do
    StripeHTTPStub.json(conn, %{
      "id" => "pi_test_member",
      "client_secret" => "pi_test_member_secret",
      "amount" => 1000,
      "currency" => "eur",
      "status" => "requires_payment_method",
      "metadata" => %{}
    })
  end

  defp stripe("GET", "/v1/payment_intents/" <> payment_intent_id, conn),
    do: StripeHTTPStub.json(conn, pi_retrieve_default(payment_intent_id))

  defp stripe(_method, _path, conn), do: StripeHTTPStub.json(conn, %{})

  defp pi_retrieve_default(payment_intent_id) do
    %{
      "id" => payment_intent_id,
      "status" => "succeeded",
      "amount" => 1000,
      "currency" => "eur",
      "metadata" => %{
        "type" => "workshop_registration",
        "actor_type" => "member",
        "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_workshop_id),
        "user_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_member_user_id)
      }
    }
  end

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp install_registration_delay!(trigger, workshop_id, ready_lock, release_lock) do
    Repo.query!("""
    CREATE FUNCTION #{trigger}() RETURNS trigger AS $$
    BEGIN
      IF NEW.club_activity_id = '#{workshop_id}'::uuid THEN
        PERFORM pg_advisory_xact_lock(#{ready_lock});
        PERFORM pg_advisory_xact_lock(#{release_lock});
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger}
    BEFORE INSERT ON club_activity_registrations
    FOR EACH ROW EXECUTE FUNCTION #{trigger}()
    """)
  end

  defp await_advisory_lock!(_lock_key, 0), do: flunk("registration did not reach the insert")

  defp await_advisory_lock!(lock_key, attempts) do
    case Repo.query!("SELECT pg_try_advisory_lock($1)", [lock_key]).rows do
      [[false]] ->
        :ok

      [[true]] ->
        Repo.query!("SELECT pg_advisory_unlock($1)", [lock_key])
        await_advisory_lock!(lock_key, attempts - 1)
    end
  end

  defp await_workshop_lock_wait!(0), do: flunk("deletion did not wait for the Workshop lock")

  defp await_workshop_lock_wait!(attempts) do
    waiting? =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
            FROM pg_stat_activity
           WHERE pid <> pg_backend_pid()
             AND wait_event_type = 'Lock'
             AND query LIKE $1
             AND query LIKE $2
        )
        """,
        ["%FROM \"club_activities\"%", "%FOR UPDATE%"]
      ).rows == [[true]]

    if waiting?, do: :ok, else: await_workshop_lock_wait!(attempts - 1)
  end
end
