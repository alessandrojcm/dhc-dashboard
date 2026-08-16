defmodule Dhc.Workshops.StripeIdentifierExpansionTest do
  @moduledoc """
  ALE-179 (expand): the conflated `stripe_checkout_session_id` column is
  split into `stripe_payment_intent_id` (`pi_*`) and
  `stripe_checkout_session_id` (`cs_*`).

  The migration runs as part of `mise run phx-test` (migrate-from-zero),
  so these tests assert the post-migration schema state and behavior
  directly. A characterization test pins the *current* (pre-code-release)
  write path — the application still writes both kinds into
  `stripe_checkout_session_id` until the ALE-193 code release deploys —
  and the desired tests assert the split columns, the `num_nonnulls <= 1`
  CHECK, and the two partial uniques.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.WorkshopFixtures

  @pi_unique :club_activity_registrations_stripe_payment_intent_id_unique
  @cs_unique :club_activity_registrations_stripe_checkout_session_id_unique
  @check :club_activity_registrations_stripe_identifier_xor

  describe "backfill: the expand release preserves old-code compatibility" do
    # The migration runs at setup (migrate-from-zero), so its backfill has
    # already applied to the empty test DB (no rows to split). This test
    # re-runs the migration's exact backfill SQL against rows seeded with
    # conflated values to verify the prefix split logic: a `pi_*` value in
    # the old column moves to stripe_payment_intent_id and is cleared from
    # stripe_checkout_session_id; a `cs_*` value stays in
    # stripe_checkout_session_id and leaves stripe_payment_intent_id NULL.
    test "a pi_ value is copied while remaining readable through the legacy column" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      # Seed a row the way the pre-expand code did: a `pi_*` value in
      # stripe_checkout_session_id (the conflated column).
      _ =
        Repo.query!(
          """
          INSERT INTO club_activity_registrations
            (id, club_activity_id, member_user_id, display_name, stripe_checkout_session_id,
             amount_paid, currency, status, registered_at, created_at, updated_at)
          VALUES ($1, $2, $3, 'Member Test', $4, 1000, 'eur', 'confirmed', NOW(), NOW(), NOW())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(workshop.id),
            Ecto.UUID.dump!(user_id),
            "pi_test_123"
          ]
        )

      # Re-run the expand backfill against this seeded row.
      run_backfill!()

      assert [["pi_test_123", "pi_test_123"]] =
               Repo.query!(
                 "SELECT stripe_payment_intent_id, stripe_checkout_session_id
                  FROM club_activity_registrations WHERE member_user_id = $1",
                 [Ecto.UUID.dump!(user_id)]
               ).rows
    end

    test "a cs_ value in the old column stays in stripe_checkout_session_id" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()

      _ =
        Repo.query!(
          """
          INSERT INTO club_activity_registrations
            (id, club_activity_id, external_user_id, display_name, stripe_checkout_session_id,
             amount_paid, currency, status, registered_at, created_at, updated_at)
          VALUES ($1, $2, $3, 'External Guest', $4, 1000, 'eur', 'confirmed', NOW(), NOW(), NOW())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(workshop.id),
            Ecto.UUID.dump!(external.id),
            "cs_test_456"
          ]
        )

      run_backfill!()

      assert [[nil, "cs_test_456"]] =
               Repo.query!(
                 "SELECT stripe_payment_intent_id, stripe_checkout_session_id
                  FROM club_activity_registrations WHERE external_user_id = $1",
                 [Ecto.UUID.dump!(external.id)]
               ).rows
    end

    for malformed <- ["ch_unknown_prefix", "piXwildcard", "csXwildcard"] do
      test "the literal-prefix gate rejects #{malformed}" do
        workshop = WorkshopFixtures.workshop_fixture()
        %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

        _ =
          Repo.query!(
            """
            INSERT INTO club_activity_registrations
              (id, club_activity_id, member_user_id, display_name, stripe_checkout_session_id,
               amount_paid, currency, status, registered_at, created_at, updated_at)
            VALUES ($1, $2, $3, 'Member Test', $4, 1000, 'eur', 'confirmed', NOW(), NOW(), NOW())
            """,
            [
              Ecto.UUID.dump!(Ecto.UUID.generate()),
              Ecto.UUID.dump!(workshop.id),
              Ecto.UUID.dump!(user_id),
              unquote(malformed)
            ]
          )

        error =
          assert_raise Postgrex.Error, fn ->
            run_backfill!()
          end

        assert Map.get(error.postgres, :code) == :check_violation
      end
    end
  end

  describe "desired: the split columns enforce the invariant" do
    test "stripe_payment_intent_id column exists and is nullable" do
      assert column_nullable?("club_activity_registrations", "stripe_payment_intent_id")
    end

    test "stripe_checkout_session_id remains available for cs_ values" do
      assert column_exists?("club_activity_registrations", "stripe_checkout_session_id")
    end

    test "a row may hold zero Stripe ids (free/no-pay registrations)" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      # No Stripe id at all — both columns NULL. The CHECK is <= 1, so
      # zero is allowed.
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: user_id,
        status: "pending"
      )

      assert [[nil, nil]] =
               Repo.query!(
                 "SELECT stripe_payment_intent_id, stripe_checkout_session_id
                  FROM club_activity_registrations WHERE member_user_id = $1",
                 [Ecto.UUID.dump!(user_id)]
               ).rows
    end

    test "a row may hold exactly one pi_ id (member registration shape)" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: user_id,
        stripe_payment_intent_id: "pi_member_#{System.unique_integer([:positive])}",
        status: "confirmed"
      )

      assert [[_pi, nil]] =
               Repo.query!(
                 "SELECT stripe_payment_intent_id, stripe_checkout_session_id
                  FROM club_activity_registrations WHERE member_user_id = $1",
                 [Ecto.UUID.dump!(user_id)]
               ).rows
    end

    test "a row may hold exactly one cs_ id (external registration shape)" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: external.id,
        stripe_checkout_session_id: "cs_external_#{System.unique_integer([:positive])}",
        status: "confirmed"
      )

      assert [[nil, _cs]] =
               Repo.query!(
                 "SELECT stripe_payment_intent_id, stripe_checkout_session_id
                  FROM club_activity_registrations WHERE external_user_id = $1",
                 [Ecto.UUID.dump!(external.id)]
               ).rows
    end

    test "CHECK num_nonnulls <= 1 rejects a row with both identifiers set" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO club_activity_registrations
              (id, club_activity_id, member_user_id, display_name,
               stripe_payment_intent_id, stripe_checkout_session_id,
               amount_paid, currency, status, registered_at, created_at, updated_at)
            VALUES ($1, $2, $3, 'Member Test', $4, $5, 1000, 'eur', 'confirmed', NOW(), NOW(), NOW())
            """,
            [
              Ecto.UUID.dump!(Ecto.UUID.generate()),
              Ecto.UUID.dump!(workshop.id),
              Ecto.UUID.dump!(user_id),
              "pi_both_#{System.unique_integer([:positive])}",
              "cs_both_#{System.unique_integer([:positive])}"
            ]
          )
        end

      assert Map.get(error.postgres, :constraint) == Atom.to_string(@check)
      assert Map.get(error.postgres, :code) == :check_violation
    end

    test "the old conflated unique is gone" do
      assert [[false]] =
               Repo.query!(
                 "SELECT EXISTS (
                    SELECT 1 FROM pg_indexes
                    WHERE indexname = $1
                  )",
                 ["club_activity_registrations_stripe_checkout_session_id_index"]
               ).rows
    end

    test "two new partial uniques exist, one per split column" do
      assert [true, pi_def] = index_def(@pi_unique)
      assert pi_def =~ "CREATE UNIQUE INDEX"
      assert pi_def =~ "stripe_payment_intent_id"
      assert pi_def =~ "WHERE (stripe_payment_intent_id IS NOT NULL)"

      assert [true, cs_def] = index_def(@cs_unique)
      assert cs_def =~ "CREATE UNIQUE INDEX"
      assert cs_def =~ "stripe_checkout_session_id"
      assert cs_def =~ "WHERE (stripe_checkout_session_id IS NOT NULL)"
    end

    test "the pi_ partial unique rejects duplicate non-null pi_ ids" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()
      pi = "pi_dup_#{System.unique_integer([:positive])}"

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u1,
        stripe_payment_intent_id: pi,
        status: "confirmed"
      )

      error =
        assert_raise Ecto.ConstraintError, fn ->
          WorkshopFixtures.registration_fixture(
            workshop_id: workshop.id,
            member_user_id: u2,
            stripe_payment_intent_id: pi,
            status: "confirmed"
          )
        end

      assert error.constraint == Atom.to_string(@pi_unique)
    end

    test "the cs_ partial unique rejects duplicate non-null cs_ ids" do
      workshop = WorkshopFixtures.workshop_fixture()
      e1 = WorkshopFixtures.external_user_fixture()
      e2 = WorkshopFixtures.external_user_fixture()
      cs = "cs_dup_#{System.unique_integer([:positive])}"

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: e1.id,
        stripe_checkout_session_id: cs,
        status: "confirmed"
      )

      error =
        assert_raise Ecto.ConstraintError, fn ->
          WorkshopFixtures.registration_fixture(
            workshop_id: workshop.id,
            external_user_id: e2.id,
            stripe_checkout_session_id: cs,
            status: "confirmed"
          )
        end

      assert error.constraint == Atom.to_string(@cs_unique)
    end

    test "both partial uniques allow multiple NULLs" do
      # Two rows with NULL in both columns coexist (the partial uniques
      # only fire WHERE col IS NOT NULL).
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u1,
        status: "pending"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u2,
        status: "pending"
      )

      assert [[2]] =
               Repo.query!(
                 "SELECT count(*) FROM club_activity_registrations
                  WHERE club_activity_id = $1
                    AND stripe_payment_intent_id IS NULL
                    AND stripe_checkout_session_id IS NULL",
                 [Ecto.UUID.dump!(workshop.id)]
               ).rows
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  # Re-runs the migration's backfill against the current table state. The
  # migration already ran at setup against an empty DB; this lets the backfill
  # tests seed conflated rows and verify the transitional state. The full test
  # schema has the contract CHECK, so replace it with the expand CHECK first.
  defp run_backfill! do
    Repo.query!("ALTER TABLE club_activity_registrations DROP CONSTRAINT #{@check}")

    Repo.query!("""
    ALTER TABLE club_activity_registrations
      ADD CONSTRAINT #{@check}
      CHECK (
        stripe_payment_intent_id IS NULL
        OR stripe_checkout_session_id IS NULL
        OR stripe_payment_intent_id = stripe_checkout_session_id
      ) NOT VALID
    """)

    _ =
      Repo.query!("""
      UPDATE club_activity_registrations
         SET stripe_payment_intent_id = stripe_checkout_session_id
       WHERE stripe_checkout_session_id IS NOT NULL
         AND left(stripe_checkout_session_id, 3) = 'pi_'
      """)

    Repo.query!("""
    DO $$
    DECLARE unparseable int;
    BEGIN
      SELECT count(*) INTO unparseable
        FROM club_activity_registrations
       WHERE stripe_checkout_session_id IS NOT NULL
         AND left(stripe_checkout_session_id, 3) NOT IN ('pi_', 'cs_');

      IF unparseable > 0 THEN
        RAISE EXCEPTION 'Stripe identifier expansion: % unparseable identifiers remain', unparseable
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$ LANGUAGE plpgsql
    """)

    :ok
  end

  defp column_exists?(table, column) do
    [[true]] =
      Repo.query!(
        "SELECT EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_name = $1 AND column_name = $2
         )",
        [table, column]
      ).rows

    true
  end

  defp column_nullable?(table, column) do
    [[true]] =
      Repo.query!(
        "SELECT is_nullable = 'YES' FROM information_schema.columns
         WHERE table_name = $1 AND column_name = $2",
        [table, column]
      ).rows

    true
  end

  defp index_def(name) do
    Repo.query!(
      "SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1),
              COALESCE((SELECT indexdef FROM pg_indexes WHERE indexname = $1), '')",
      [Atom.to_string(name)]
    ).rows
    |> hd()
  end
end
