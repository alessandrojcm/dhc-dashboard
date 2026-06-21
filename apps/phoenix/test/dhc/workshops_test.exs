defmodule Dhc.WorkshopsTest do
  @moduledoc """
  Context-level read-model tests for `Dhc.Workshops` (issue #143 prefactor).

  Covers the read-model behavior needed by the three later endpoint slices
  from PRD #142:

    * **Member collection** — Workshop visibility, interest counts,
      pending/confirmed registration counts, current-user interest/registration
      state, and the absence of other attendee identities in the summary.
    * **Coordinator calendar** — non-cancelled filtering, interest +
      registration counts, deterministic ordering.
    * **Attendee/refund management** — attendee status filtering, refund
      inclusion, normalized member/external participant identity, and the
      combined attendee/refund payload.

  These tests assert external read-model behavior (shape, counts, filtering,
  participant normalization) — not internal query mechanics. RBAC itself is
  documented in the `Dhc.Workshops` moduledoc and asserted at the role-list
  level here; controller-layer authorization is verified by future endpoint
  slices.
  """

  use Dhc.DataCase, async: false

  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  # `:binary_id` fields load as 16-byte binaries; normalize to the string UUID
  # form so assertions read against the fixture's string ids.
  defp uuid_to_string(<<_::128>> = value) do
    {:ok, string} = Ecto.UUID.load(value)
    string
  end

  defp uuid_to_string(value), do: value

  # ── RBAC / vocabulary ─────────────────────────────────────────────────

  describe "coordinator_management_roles/0 — RBAC drift" do
    test "includes workshop_coordinator, president, admin and NOT beginners_coordinator" do
      roles = Workshops.coordinator_management_roles()

      assert "workshop_coordinator" in roles
      assert "president" in roles
      assert "admin" in roles
      # The historical registration RLS policy granted beginners_coordinator
      # full registration visibility. That was drift (see Dhc.Workshops
      # moduledoc). The Phoenix read model must not reproduce it.
      refute "beginners_coordinator" in roles
    end
  end

  describe "member_visible_statuses/0" do
    test "returns planned and published only" do
      assert Workshops.member_visible_statuses() == ["planned", "published"]
    end
  end

  # ── Workshop summaries: member collection ─────────────────────────────

  describe "list_workshop_summaries/1 — member collection" do
    test "returns only member-visible statuses when filtered to them" do
      planned = WorkshopFixtures.workshop_fixture(title: "Planned", status: "planned")
      published = WorkshopFixtures.workshop_fixture(title: "Published", status: "published")
      WorkshopFixtures.workshop_fixture(title: "Finished", status: "finished")
      WorkshopFixtures.workshop_fixture(title: "Cancelled", status: "cancelled")

      summaries = Workshops.list_workshop_summaries(statuses: Workshops.member_visible_statuses())

      titles = Enum.map(summaries, & &1.title)
      assert "Planned" in titles
      assert "Published" in titles
      refute "Finished" in titles
      refute "Cancelled" in titles
      assert length(summaries) == 2
    end

    test "orders by start_date ascending by default" do
      later =
        WorkshopFixtures.workshop_fixture(title: "Later", start_date: ~U[2026-08-01 10:00:00Z])

      earlier =
        WorkshopFixtures.workshop_fixture(title: "Earlier", start_date: ~U[2026-06-01 10:00:00Z])

      summaries = Workshops.list_workshop_summaries(statuses: ~w(planned))

      assert Enum.map(summaries, & &1.title) == ["Earlier", "Later"]
      assert uuid_to_string(summaries |> hd() |> Map.get(:id)) == uuid_to_string(earlier.id)
      assert uuid_to_string(summaries |> Enum.at(1) |> Map.get(:id)) == uuid_to_string(later.id)
    end

    test "interest_count reflects expressed interest" do
      workshop = WorkshopFixtures.workshop_fixture(status: "planned")
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture(first_name: "A", last_name: "B")
      %{auth_user_id: u2} = WorkshopFixtures.member_fixture(first_name: "C", last_name: "D")
      WorkshopFixtures.interest_fixture(workshop.id, u1)
      WorkshopFixtures.interest_fixture(workshop.id, u2)

      [summary] = Workshops.list_workshop_summaries(statuses: ~w(planned))

      assert summary.interest_count == 2
    end

    test "pending and confirmed registration counts are reported separately" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()
      %{auth_user_id: u3} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u1,
        status: "pending"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u2,
        status: "confirmed"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u3,
        status: "confirmed"
      )

      [summary] = Workshops.list_workshop_summaries(statuses: ~w(published))

      assert summary.pending_registration_count == 1
      assert summary.confirmed_registration_count == 2
    end

    test "cancelled and refunded registrations are not counted toward availability" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u1,
        status: "cancelled"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u2,
        status: "refunded"
      )

      [summary] = Workshops.list_workshop_summaries(statuses: ~w(published))

      assert summary.pending_registration_count == 0
      assert summary.confirmed_registration_count == 0
    end

    test "the summary does not expose other attendee identities" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")

      %{auth_user_id: u1} =
        WorkshopFixtures.member_fixture(first_name: "Secret", last_name: "Member")

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u1,
        status: "confirmed"
      )

      [summary] = Workshops.list_workshop_summaries(statuses: ~w(published))

      # The summary carries counts only — no attendee rows, no participant
      # identities. Those live behind the coordinator attendee/refund read.
      refute Map.has_key?(summary, :attendees)
      refute Map.has_key?(summary, :participant)
      refute Map.has_key?(summary, :member_first_name)
      refute Map.has_key?(summary, :attendee_count)
    end

    test "summary DTOs use Workshop vocabulary, not club_activity* field names" do
      WorkshopFixtures.workshop_fixture(status: "planned")

      [summary] = Workshops.list_workshop_summaries(statuses: ~w(planned))

      # Domain fields present.
      for field <-
            ~w(id title description location start_date end_date max_capacity price_member price_non_member is_public refund_days status interest_count pending_registration_count confirmed_registration_count)a do
        assert Map.has_key?(summary, field), "missing domain field #{inspect(field)}"
      end

      # Persistence/internal names absent from the public DTO.
      refute Map.has_key?(summary, :club_activity_id)
      refute Map.has_key?(summary, :club_activity_status)
      refute Map.has_key?(summary, :user_interest)
      refute Map.has_key?(summary, :user_registrations)
    end
  end

  # ── Workshop summaries: coordinator calendar ──────────────────────────

  describe "list_workshop_summaries/1 — coordinator calendar" do
    test "excludes cancelled Workshops when exclude_statuses is used" do
      WorkshopFixtures.workshop_fixture(title: "Planned", status: "planned")
      WorkshopFixtures.workshop_fixture(title: "Published", status: "published")
      WorkshopFixtures.workshop_fixture(title: "Finished", status: "finished")
      cancelled = WorkshopFixtures.workshop_fixture(title: "Cancelled", status: "cancelled")

      summaries = Workshops.list_workshop_summaries(exclude_statuses: ~w(cancelled))

      titles = Enum.map(summaries, & &1.title)
      assert "Planned" in titles
      assert "Published" in titles
      assert "Finished" in titles
      refute "Cancelled" in titles
      assert length(summaries) == 3
      refute uuid_to_string(cancelled.id) in Enum.map(summaries, &uuid_to_string(&1.id))
    end

    test "registration counts cover pending and confirmed across many registrations" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")

      for _ <- 1..3 do
        %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "pending"
        )
      end

      for _ <- 1..2 do
        %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "confirmed"
        )
      end

      # Only the published workshop exists in this test's sandbox, so the
      # non-cancelled list returns exactly its summary.
      [summary] = Workshops.list_workshop_summaries(exclude_statuses: ~w(cancelled))

      assert summary.pending_registration_count == 3
      assert summary.confirmed_registration_count == 2
    end

    test "interest_count and registration counts coexist without cross-inflation" do
      # A workshop with both interests and registrations must not have its
      # interest count inflated by the registration join (or vice versa).
      workshop = WorkshopFixtures.workshop_fixture(status: "published")

      %{auth_user_id: i1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: i2} = WorkshopFixtures.member_fixture()
      WorkshopFixtures.interest_fixture(workshop.id, i1)
      WorkshopFixtures.interest_fixture(workshop.id, i2)

      %{auth_user_id: r1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: r2} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: r1,
        status: "confirmed"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: r2,
        status: "pending"
      )

      [summary] =
        Workshops.list_workshop_summaries(exclude_statuses: ~w(cancelled))
        |> Enum.filter(&(&1.status == "published"))

      assert summary.interest_count == 2
      assert summary.pending_registration_count == 1
      assert summary.confirmed_registration_count == 1
    end

    test "the calendar summary does not carry current-user registration data" do
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()
      workshop = WorkshopFixtures.workshop_fixture(status: "published", created_by: nil)

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: user_id,
        status: "confirmed"
      )

      [summary] =
        Workshops.list_workshop_summaries(exclude_statuses: ~w(cancelled))
        |> Enum.filter(&(&1.id == workshop.id))

      # The calendar DTO must not carry current-user registration artifacts
      # (PRD #142: that was a PostgREST join artifact). The summary is
      # user-agnostic; current-user state is a separate helper.
      refute Map.has_key?(summary, :current_user_registration)
      refute Map.has_key?(summary, :user_registrations)
      refute Map.has_key?(summary, :user_interest)
    end
  end

  # ── Single workshop summary ───────────────────────────────────────────

  describe "workshop_summary/1" do
    test "returns the summary for an existing Workshop" do
      workshop = WorkshopFixtures.workshop_fixture(title: "Solo", status: "published")
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed"
      )

      summary = Workshops.workshop_summary(workshop.id)

      assert summary.title == "Solo"
      assert summary.status == "published"
      assert summary.confirmed_registration_count == 1
      assert uuid_to_string(summary.id) == uuid_to_string(workshop.id)
    end

    test "returns nil for a missing Workshop" do
      missing_id = Ecto.UUID.generate()

      assert Workshops.workshop_summary(missing_id) == nil
    end
  end

  # ── Counts ────────────────────────────────────────────────────────────

  describe "interest_count/1" do
    test "counts interests for a Workshop" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()
      WorkshopFixtures.interest_fixture(workshop.id, u1)
      WorkshopFixtures.interest_fixture(workshop.id, u2)

      assert Workshops.interest_count(workshop.id) == 2
    end

    test "returns 0 for a Workshop with no interest" do
      workshop = WorkshopFixtures.workshop_fixture()

      assert Workshops.interest_count(workshop.id) == 0
    end
  end

  describe "registration_counts/1" do
    test "reports pending and confirmed counts" do
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
        status: "confirmed"
      )

      counts = Workshops.registration_counts(workshop.id)

      assert counts == %{pending: 1, confirmed: 1}
    end

    test "returns zeroed counts for a Workshop with no registrations" do
      workshop = WorkshopFixtures.workshop_fixture()

      assert Workshops.registration_counts(workshop.id) == %{pending: 0, confirmed: 0}
    end
  end

  # ── Current-user state ────────────────────────────────────────────────

  describe "current_user_interest?/2" do
    test "is true when the member expressed interest" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()
      WorkshopFixtures.interest_fixture(workshop.id, uid)

      assert Workshops.current_user_interest?(workshop.id, uid) == true
    end

    test "is false when the member has not expressed interest" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      assert Workshops.current_user_interest?(workshop.id, uid) == false
    end
  end

  describe "current_user_registration/2" do
    test "returns the member's registration id and status" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "confirmed"
        )

      result = Workshops.current_user_registration(workshop.id, uid)

      assert uuid_to_string(result.id) == uuid_to_string(reg.id)
      assert result.status == "confirmed"
    end

    test "returns nil when the member has no registration" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      assert Workshops.current_user_registration(workshop.id, uid) == nil
    end

    test "returns a refunded registration so the endpoint can derive refunded state" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "refunded"
      )

      assert %{status: "refunded"} = Workshops.current_user_registration(workshop.id, uid)
    end
  end

  # ── Attendees ─────────────────────────────────────────────────────────

  describe "list_workshop_attendees/1" do
    test "returns only confirmed and pending registrations" do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: confirmed_uid} =
        WorkshopFixtures.member_fixture(first_name: "Con", last_name: "Firmed")

      %{auth_user_id: pending_uid} =
        WorkshopFixtures.member_fixture(first_name: "Pen", last_name: "Ding")

      %{auth_user_id: cancelled_uid} =
        WorkshopFixtures.member_fixture(first_name: "Can", last_name: "Celled")

      %{auth_user_id: refunded_uid} =
        WorkshopFixtures.member_fixture(first_name: "Ref", last_name: "Unded")

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: confirmed_uid,
        status: "confirmed"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: pending_uid,
        status: "pending"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: cancelled_uid,
        status: "cancelled"
      )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: refunded_uid,
        status: "refunded"
      )

      attendees = Workshops.list_workshop_attendees(workshop.id)

      statuses = Enum.map(attendees, & &1.status) |> Enum.sort()
      assert statuses == ["confirmed", "pending"]
      assert length(attendees) == 2
    end

    test "orders attendees by created_at ascending" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture(first_name: "First", last_name: "Reg")

      %{auth_user_id: u2} =
        WorkshopFixtures.member_fixture(first_name: "Second", last_name: "Reg")

      earlier = ~U[2026-06-01 10:00:00Z]
      later = ~U[2026-06-02 10:00:00Z]

      # Insert in reverse chronological order to prove the read orders by
      # created_at, not insertion order.
      second_reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u2,
          status: "confirmed",
          created_at: later
        )

      first_reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u1,
          status: "confirmed",
          created_at: earlier
        )

      attendees = Workshops.list_workshop_attendees(workshop.id)

      assert uuid_to_string(hd(attendees).id) == uuid_to_string(first_reg.id)
      assert uuid_to_string(Enum.at(attendees, 1).id) == uuid_to_string(second_reg.id)
    end

    test "normalizes a member participant with display name and no email" do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: uid} =
        WorkshopFixtures.member_fixture(first_name: "Ada", last_name: "Lovelace")

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed"
      )

      [attendee] = Workshops.list_workshop_attendees(workshop.id)

      assert attendee.participant == %{
               type: :member,
               display_name: "Ada Lovelace",
               email: nil
             }
    end

    test "normalizes an external participant with display name and email" do
      workshop = WorkshopFixtures.workshop_fixture()

      ext =
        WorkshopFixtures.external_user_fixture(
          first_name: "Grace",
          last_name: "Hopper",
          email: "grace@example.com"
        )

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        external_user_id: ext.id,
        status: "confirmed"
      )

      [attendee] = Workshops.list_workshop_attendees(workshop.id)

      assert attendee.participant == %{
               type: :external,
               display_name: "Grace Hopper",
               email: "grace@example.com"
             }
    end

    test "attendee DTO uses Workshop vocabulary and hides the storage join" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: uid,
        status: "confirmed"
      )

      [attendee] = Workshops.list_workshop_attendees(workshop.id)

      # Domain fields present.
      for field <- ~w(id status attendance_status amount_paid currency registered_at participant)a do
        assert Map.has_key?(attendee, field), "missing domain field #{inspect(field)}"
      end

      # Storage join shapes absent — participant is normalized.
      refute Map.has_key?(attendee, :user_profiles)
      refute Map.has_key?(attendee, :external_users)
      refute Map.has_key?(attendee, :member_first_name)
      refute Map.has_key?(attendee, :external_first_name)
    end

    test "returns an empty list for a Workshop with no matching registrations" do
      workshop = WorkshopFixtures.workshop_fixture()

      assert Workshops.list_workshop_attendees(workshop.id) == []
    end
  end

  # ── Refunds ───────────────────────────────────────────────────────────

  describe "list_workshop_refunds/1" do
    test "returns refunds for the Workshop's registrations regardless of refund status" do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()

      reg1 =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u1,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg1.id, status: "pending")

      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()

      reg2 =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u2,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg2.id, status: "completed")

      # A third registration with no refund proves refunds are not invented
      # and that the read only returns rows that exist.
      %{auth_user_id: u3} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: u3,
        status: "confirmed"
      )

      refunds = Workshops.list_workshop_refunds(workshop.id)

      # No status filter — both pending and completed refunds are returned.
      assert length(refunds) == 2
      statuses = Enum.map(refunds, & &1.status) |> Enum.sort()
      assert statuses == ["completed", "pending"]
    end

    test "orders refunds by requested_at descending" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: u1} = WorkshopFixtures.member_fixture()
      %{auth_user_id: u2} = WorkshopFixtures.member_fixture()

      reg1 =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u1,
          status: "refunded"
        )

      reg2 =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: u2,
          status: "refunded"
        )

      earlier = ~U[2026-06-01 10:00:00Z]
      later = ~U[2026-06-02 10:00:00Z]

      WorkshopFixtures.refund_fixture(registration_id: reg1.id, requested_at: earlier)
      WorkshopFixtures.refund_fixture(registration_id: reg2.id, requested_at: later)

      refunds = Workshops.list_workshop_refunds(workshop.id)

      assert Enum.map(refunds, & &1.requested_at) == [later, earlier]
    end

    test "normalizes a member participant on a refund" do
      workshop = WorkshopFixtures.workshop_fixture()

      %{auth_user_id: uid} =
        WorkshopFixtures.member_fixture(first_name: "Alan", last_name: "Turing")

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      [refund] = Workshops.list_workshop_refunds(workshop.id)

      assert refund.participant == %{
               type: :member,
               display_name: "Alan Turing",
               email: nil
             }
    end

    test "normalizes an external participant on a refund" do
      workshop = WorkshopFixtures.workshop_fixture()

      ext =
        WorkshopFixtures.external_user_fixture(
          first_name: "Katherine",
          last_name: "Johnson",
          email: "katherine@example.com"
        )

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          external_user_id: ext.id,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      [refund] = Workshops.list_workshop_refunds(workshop.id)

      assert refund.participant == %{
               type: :external,
               display_name: "Katherine Johnson",
               email: "katherine@example.com"
             }
    end

    test "refund DTO uses Workshop vocabulary and hides the storage join" do
      workshop = WorkshopFixtures.workshop_fixture()
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "refunded"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      [refund] = Workshops.list_workshop_refunds(workshop.id)

      for field <-
            ~w(id registration_id refund_amount refund_reason status requested_at participant)a do
        assert Map.has_key?(refund, field), "missing domain field #{inspect(field)}"
      end

      refute Map.has_key?(refund, :user_profiles)
      refute Map.has_key?(refund, :external_users)
      refute Map.has_key?(refund, :club_activity_registrations)
    end

    test "returns an empty list for a Workshop with no refunds" do
      workshop = WorkshopFixtures.workshop_fixture()

      assert Workshops.list_workshop_refunds(workshop.id) == []
    end
  end

  # ── Combined attendee/refund payload ──────────────────────────────────

  describe "workshop_attendees_and_refunds/1" do
    test "returns workshop summary, attendees, and refunds together" do
      workshop = WorkshopFixtures.workshop_fixture(title: "Managed", status: "published")

      %{auth_user_id: uid} =
        WorkshopFixtures.member_fixture(first_name: "Member", last_name: "One")

      reg =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "confirmed"
        )

      WorkshopFixtures.refund_fixture(registration_id: reg.id)

      result = Workshops.workshop_attendees_and_refunds(workshop.id)

      assert result.workshop.title == "Managed"
      assert length(result.attendees) == 1
      assert length(result.refunds) == 1
      assert hd(result.attendees).participant.type == :member
      assert hd(result.refunds).participant.type == :member
    end

    test "returns nil workshop for a missing Workshop (so endpoints can 404)" do
      missing_id = Ecto.UUID.generate()

      result = Workshops.workshop_attendees_and_refunds(missing_id)

      assert result.workshop == nil
      assert result.attendees == []
      assert result.refunds == []
    end
  end
end
