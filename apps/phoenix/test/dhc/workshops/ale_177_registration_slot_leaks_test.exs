defmodule Dhc.Workshops.Ale177RegistrationSlotLeaksTest do
  @moduledoc """
  ALE-177: cancelled and refunded Registrations free their slot for
  re-registration. The migration drops the two full
  `UNIQUE(member_id, club_activity_id)` uniques (one for member, one for
  external participants) and replaces them with partial uniques
  `WHERE status IN ('pending','confirmed')`, so a historical
  cancelled/refunded row no longer blocks a fresh registration for the same
  member and workshop.

  The migration also adds the `exactly_one_participant` XOR CHECK
  idempotently via a `pg_constraint` guard (re-running on an already-migrated
  DB does not error), and a `(club_activity_id, created_at, id)` partial
  composite index so summary and calendar queries perform.

  The migration runs as part of `mise run phx-test` (migrate-from-zero), so
  these tests assert the post-migration schema state and behavior directly.

  Coverage (5 re-registration scenarios + companion assertions for the
  remaining acceptance criteria):

    1. A cancelled member registration frees the slot — a fresh pending
       registration for the same (member, workshop) is allowed.
    2. A refunded member registration frees the slot — a fresh confirmed
       registration for the same (member, workshop) is allowed.
    3. A cancelled external registration frees the slot — a fresh pending
       registration for the same (external, workshop) is allowed.
    4. A refunded external registration frees the slot — a fresh confirmed
       registration for the same (external, workshop) is allowed.
    5. Re-register after cancelled, then cancel and re-register again — two
       historical cancelled rows coexist with a fresh active row (the full
       unique would have blocked the second insert).

  Companion assertions (the remaining acceptance criteria):

    * The partial unique still blocks a duplicate *active* registration
      (two pending/confirmed rows for the same participant+workshop raise).
    * The `exactly_one_participant` XOR CHECK rejects a row with neither
      participant id set and a row with both set, and is added idempotently
      (the constraint exists exactly once).
    * The `(club_activity_id, created_at, id)` partial composite index
      exists with the pending/confirmed predicate.
    * The old full uniques are dropped; the new partial uniques exist.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.WorkshopFixtures

  @member_unique :club_activity_registrations_member_user_id_active_unique
  @external_unique :club_activity_registrations_external_user_id_active_unique
  @composite_index :club_activity_registrations_activity_created_at_id_index
  @xor_check :exactly_one_participant

  describe "re-registration: a cancelled/refunded row frees the slot" do
    @tag :ale_177
    test "a cancelled member registration frees the slot for a fresh pending row" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "cancelled",
        display_name: "First Attempt"
      )

      # The partial unique only spans pending/confirmed, so the cancelled row
      # does not collide and the fresh pending registration inserts cleanly.
      assert {:ok, _second} =
               %{
                 workshop_id: workshop.id,
                 member_user_id: uid,
                 status: "pending",
                 display_name: "Second Attempt"
               }
               |> WorkshopFixtures.registration_fixture()
               |> then(&{:ok, &1})
    end

    @tag :ale_177
    test "a refunded member registration frees the slot for a fresh confirmed row" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "refunded",
        display_name: "Refunded Attempt"
      )

      assert {:ok, _second} =
               %{
                 workshop_id: workshop.id,
                 member_user_id: uid,
                 status: "confirmed",
                 display_name: "Re-registered"
               }
               |> WorkshopFixtures.registration_fixture()
               |> then(&{:ok, &1})
    end

    @tag :ale_177
    test "a cancelled external registration frees the slot for a fresh pending row" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: external.id,
        status: "cancelled",
        display_name: "First External"
      )

      assert {:ok, _second} =
               %{
                 workshop_id: workshop.id,
                 external_user_id: external.id,
                 status: "pending",
                 display_name: "Second External"
               }
               |> WorkshopFixtures.registration_fixture()
               |> then(&{:ok, &1})
    end

    @tag :ale_177
    test "a refunded external registration frees the slot for a fresh confirmed row" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: external.id,
        status: "refunded",
        display_name: "Refunded External"
      )

      assert {:ok, _second} =
               %{
                 workshop_id: workshop.id,
                 external_user_id: external.id,
                 status: "confirmed",
                 display_name: "Re-registered External"
               }
               |> WorkshopFixtures.registration_fixture()
               |> then(&{:ok, &1})
    end

    @tag :ale_177
    test "re-register after cancelled, then cancel and re-register again (the slot stays free)" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      # First attempt: cancelled.
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "cancelled",
        display_name: "First Attempt"
      )

      # Re-register after the cancelled row — the partial unique lets this in.
      second =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "confirmed",
          display_name: "Second Attempt"
        )

      # Cancel the re-registration too, then re-register a third time. Two
      # historical cancelled rows now coexist with a fresh active row, which
      # the full unique would have blocked at the second insert.
      {1, nil} =
        Repo.update_all(
          from(r in Dhc.Workshops.Registration, where: r.id == ^second.id),
          set: [status: "cancelled"]
        )

      assert {:ok, _third} =
               %{
                 workshop_id: workshop.id,
                 member_user_id: uid,
                 status: "pending",
                 display_name: "Third Attempt"
               }
               |> WorkshopFixtures.registration_fixture()
               |> then(&{:ok, &1})
    end
  end

  describe "the partial unique still blocks duplicate active registrations" do
    @tag :ale_177
    test "two pending member registrations for the same (member, workshop) raise" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "pending",
        display_name: "First Pending"
      )

      error =
        assert_raise Ecto.ConstraintError, fn ->
          WorkshopFixtures.registration_fixture(
            workshop_id: workshop.id,
            member_user_id: uid,
            status: "pending",
            display_name: "Second Pending"
          )
        end

      assert error.constraint == Atom.to_string(@member_unique)
    end

    @tag :ale_177
    test "two confirmed external registrations for the same (external, workshop) raise" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: external.id,
        status: "confirmed",
        display_name: "First Confirmed"
      )

      error =
        assert_raise Ecto.ConstraintError, fn ->
          WorkshopFixtures.registration_fixture(
            workshop_id: workshop.id,
            external_user_id: external.id,
            status: "confirmed",
            display_name: "Second Confirmed"
          )
        end

      assert error.constraint == Atom.to_string(@external_unique)
    end
  end

  describe "the XOR CHECK (exactly_one_participant) is enforced at the DB layer" do
    @tag :ale_177
    test "a row with neither member_user_id nor external_user_id is rejected" do
      workshop = WorkshopFixtures.workshop_fixture()

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO club_activity_registrations
              (id, club_activity_id, display_name, amount_paid, currency,
               status, registered_at, created_at, updated_at)
            VALUES ($1, $2, 'No Participant', 1000, 'eur', 'pending', NOW(), NOW(), NOW())
            """,
            [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(workshop.id)]
          )
        end

      assert Map.get(error.postgres, :code) == :check_violation
    end

    @tag :ale_177
    test "a row with both member_user_id and external_user_id is rejected" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()
      external = WorkshopFixtures.external_user_fixture()

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            """
            INSERT INTO club_activity_registrations
              (id, club_activity_id, member_user_id, external_user_id, display_name,
               amount_paid, currency, status, registered_at, created_at, updated_at)
            VALUES ($1, $2, $3, $4, 'Both Participants', 1000, 'eur', 'pending', NOW(), NOW(), NOW())
            """,
            [
              Ecto.UUID.dump!(Ecto.UUID.generate()),
              Ecto.UUID.dump!(workshop.id),
              Ecto.UUID.dump!(uid),
              Ecto.UUID.dump!(external.id)
            ]
          )
        end

      assert Map.get(error.postgres, :code) == :check_violation
    end

    @tag :ale_177
    test "the XOR CHECK is idempotent — the constraint exists exactly once" do
      assert [[1]] =
               Repo.query!(
                 "SELECT count(*) FROM pg_constraint
                   WHERE conname = $1
                     AND conrelid = 'club_activity_registrations'::regclass
                     AND contype = 'c'",
                 [Atom.to_string(@xor_check)]
               ).rows
    end
  end

  describe "the (club_activity_id, created_at, id) partial composite index exists" do
    @tag :ale_177
    test "the composite index exists with the expected column order and partial predicate" do
      assert [true, defn] = index_def(@composite_index)
      assert defn =~ "CREATE INDEX"
      assert defn =~ "(club_activity_id, created_at, id)"
      assert defn =~ "'pending'::registration_status"
      assert defn =~ "'confirmed'::registration_status"
    end
  end

  describe "the old full uniques are gone" do
    @tag :ale_177
    test "the full member unique is dropped" do
      # The baseline default name
      # (`club_activity_registrations_club_activity_id_member_user_id_index`,
      # 65 chars) is silently truncated by Postgres to its 63-byte identifier
      # limit; match by prefix so the query does not pass an over-long
      # `name` parameter (Postgrex rejects names >= 64 bytes).
      assert [[0]] =
               Repo.query!(
                 "SELECT count(*) FROM pg_indexes
                  WHERE schemaname = 'public'
                    AND tablename = 'club_activity_registrations'
                    AND indexname LIKE $1",
                 ["club_activity_registrations_club_activity_id_member_user_id%"]
               ).rows
    end

    @tag :ale_177
    test "the full external unique is dropped" do
      assert [[0]] =
               Repo.query!(
                 "SELECT count(*) FROM pg_indexes
                  WHERE schemaname = 'public'
                    AND tablename = 'club_activity_registrations'
                    AND indexname LIKE $1",
                 ["club_activity_registrations_club_activity_id_external_user_id%"]
               ).rows
    end

    @tag :ale_177
    test "the new member partial unique exists with the pending/confirmed predicate" do
      assert [true, defn] = index_def(@member_unique)
      assert defn =~ "CREATE UNIQUE INDEX"
      assert defn =~ "member_user_id"
      assert defn =~ "'pending'::registration_status"
      assert defn =~ "'confirmed'::registration_status"
    end

    @tag :ale_177
    test "the new external partial unique exists with the pending/confirmed predicate" do
      assert [true, defn] = index_def(@external_unique)
      assert defn =~ "CREATE UNIQUE INDEX"
      assert defn =~ "external_user_id"
      assert defn =~ "'pending'::registration_status"
      assert defn =~ "'confirmed'::registration_status"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp index_def(name) do
    Repo.query!(
      "SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1),
              COALESCE((SELECT indexdef FROM pg_indexes WHERE indexname = $1), '')",
      [Atom.to_string(name)]
    )
    |> Map.get(:rows)
    |> hd()
  end
end
