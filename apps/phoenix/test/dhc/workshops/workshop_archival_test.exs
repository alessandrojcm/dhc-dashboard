defmodule Dhc.Workshops.WorkshopArchivalTest do
  @moduledoc """
  ALE-181: Workshop soft-delete + attendee snapshot + financial-tail FK repoints.

  The migration runs as part of `mise run phx-test` (migrate-from-zero), so
  these tests assert the post-migration schema state and behavior directly.

  Coverage (9 characterization tests):

    1. **Cascade — RESTRICT FKs**: deleting a Workshop that has a registration
       is blocked by the RESTRICT FK, not cascaded (financial-tail retention).
    2. **Cascade — RESTRICT on refunds→registrations**: deleting a registration
       that has a refund is blocked by the RESTRICT FK.
    3. **Archive — registrations-existence gates archive-vs-hard-delete**: a
       Workshop with a registration is archived (`archived_at` set), not
       hard-deleted.
    4. **Archive — archived Workshop is excluded from summaries**: the
       `archived_at IS NULL` filter drops archived Workshops out of
       `list_workshop_summaries/1` and `workshop_summary/1`.
    5. **Snapshot reads — attendee reads the snapshot, not a live join**:
       `list_workshop_attendees/1` returns the registration's `display_name`/
       `email` snapshot, so anonymizing the profile does not corrupt the read.
    6. **Snapshot reads — refund reads the snapshot, not a live join**:
       `list_workshop_refunds/1` returns the snapshot on the registration, not
       a live join to `user_profiles`/`external_users`.
    7. **Delete branch — Workshop with no registrations is hard-deleted**:
       returns `{:ok, :deleted}` and the row is gone.
    8. **Delete branch — already-archived Workshop is 409**:
       `delete_workshop/1` on an archived Workshop returns
       `{:error, :already_archived}`.
    9. **Delete branch — status gate is dropped**: a published Workshop with
       no registrations is hard-deleted (the old `:not_deletable` status gate
       is gone).
  """

  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops
  alias Dhc.Workshops.{Registration, Workshop}

  @registrations_activity_fk :club_activity_registrations_club_activity_id_fkey
  @refunds_registration_fk :club_activity_refunds_registration_id_fkey

  # ── Cascade — RESTRICT FKs ─────────────────────────────────────────────

  describe "cascade — financial-tail FKs are RESTRICT" do
    @tag :workshop_archival
    test "deleting a Workshop with a registration is blocked by the RESTRICT FK" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed",
        display_name: "Member One"
      )

      # A raw SQL delete of the Workshop is blocked by the RESTRICT FK — the
      # financial-tail registration row is retained permanently.
      assert_raise Postgrex.Error, fn ->
        Repo.query!("DELETE FROM club_activities WHERE id = $1", [Ecto.UUID.dump!(workshop.id)])
      end

      assert %Postgrex.Error{postgres: %{code: :foreign_key_violation}} =
               catch_error(
                 Repo.query!("DELETE FROM club_activities WHERE id = $1", [
                   Ecto.UUID.dump!(workshop.id)
                 ])
               )

      # Confirm it is the RESTRICT FK (not some other constraint).
      assert constraint_is_restrict?(@registrations_activity_fk)
    end

    @tag :workshop_archival
    test "deleting a registration with a refund is blocked by the RESTRICT FK" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "refunded",
          display_name: "Refunded Member"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "DELETE FROM club_activity_registrations WHERE id = $1",
          [Ecto.UUID.dump!(reg.id)]
        )
      end

      assert constraint_is_restrict?(@refunds_registration_fk)
    end
  end

  # ── Archive — registrations-existence gates archive-vs-hard-delete ──────

  describe "archive — registrations-existence gates archive-vs-hard-delete" do
    @tag :workshop_archival
    test "a Workshop with a registration is archived, not hard-deleted" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed",
        display_name: "Member One"
      )

      assert {:ok, :archived, summary} = Workshops.delete_workshop(workshop.id)
      assert summary.id == workshop.id

      # The row is retained with archived_at set — the financial-tail
      # registration row is preserved.
      assert %Workshop{archived_at: %DateTime{}} = Repo.get(Workshop, workshop.id)
    end

    @tag :workshop_archival
    test "an archived Workshop is excluded from summaries" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", title: "Archived")
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed",
        display_name: "Member One"
      )

      assert {:ok, :archived, _} = Workshops.delete_workshop(workshop.id)

      # summary_query filters archived_at IS NULL, so the archived Workshop
      # drops out of both the list and the single read.
      titles = Enum.map(Workshops.list_workshop_summaries(), & &1.title)
      refute "Archived" in titles

      assert Workshops.workshop_summary(workshop.id) == nil
    end
  end

  # ── Snapshot reads ─────────────────────────────────────────────────────

  describe "snapshot reads — attendee/refund read the snapshot, not a live join" do
    @tag :workshop_archival
    test "list_workshop_attendees/1 reads the snapshot, so anonymizing the profile does not corrupt it" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid, profile_id: profile_id} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed",
        display_name: "Original Name",
        email: "original@example.com"
      )

      # Anonymize the profile after the registration was written.
      _ =
        Repo.query!(
          "UPDATE user_profiles SET first_name = 'Anon', last_name = 'Anon' WHERE id = $1",
          [Ecto.UUID.dump!(profile_id)]
        )

      [attendee] = Workshops.list_workshop_attendees(workshop.id)

      # The snapshot is stable — the read does not reflect the profile change.
      assert attendee.participant == %{
               type: :member,
               display_name: "Original Name",
               email: "original@example.com"
             }
    end

    @tag :workshop_archival
    test "list_workshop_refunds/1 reads the snapshot, not a live join" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "refunded",
          display_name: "Refunded Name",
          email: "refunded@example.com"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      [refund] = Workshops.list_workshop_refunds(workshop.id)

      assert refund.participant == %{
               type: :member,
               display_name: "Refunded Name",
               email: "refunded@example.com"
             }
    end
  end

  # ── Delete branches ────────────────────────────────────────────────────

  describe "delete branches" do
    @tag :workshop_archival
    test "a Workshop with no registrations is hard-deleted" do
      workshop = WorkshopFixtures.workshop_fixture(status: "planned")

      assert {:ok, :deleted} = Workshops.delete_workshop(workshop.id)
      assert Repo.get(Workshop, workshop.id) == nil
    end

    @tag :workshop_archival
    test "an already-archived Workshop returns {:error, :already_archived}" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed",
        display_name: "Member One"
      )

      assert {:ok, :archived, _} = Workshops.delete_workshop(workshop.id)
      assert {:error, :already_archived} = Workshops.delete_workshop(workshop.id)
    end

    @tag :workshop_archival
    test "the status gate is dropped — a published Workshop with no registrations is hard-deleted" do
      # The old behavior rejected a published Workshop with `:not_deletable`.
      # ALE-181 dropped the status gate; registrations-existence is the only
      # gate, so a published Workshop with no registrations hard-deletes.
      workshop = WorkshopFixtures.workshop_fixture(status: "published")

      assert {:ok, :deleted} = Workshops.delete_workshop(workshop.id)
      assert Repo.get(Workshop, workshop.id) == nil
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp constraint_is_restrict?(constraint_name) do
    [[delete_action]] =
      Repo.query!(
        """
        SELECT confdeltype
          FROM pg_constraint
         WHERE conname = $1
        """,
        [Atom.to_string(constraint_name)]
      ).rows

    # 'r' = RESTRICT, 'c' = CASCADE, 'a' = NO ACTION, 'n' = SET NULL, 'd' = SET DEFAULT
    delete_action == "r"
  end
end
