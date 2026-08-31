defmodule Dhc.OptimisticLockTest do
  @moduledoc """
  ALE-265 Phase 1.1: optimistic-concurrency version-witness behavior.

  Every mutable schema gains `lock_version` (integer, NOT NULL, default 1).
  Every update path — including `Ecto.Multi` flows (inventory item update)
  and command endpoints (move, maintenance) — bumps the version, and a stale
  write raises `Ecto.StaleEntryError`. Payment/refund/workflow tables are
  excluded by contract (ADR 0023).

  The wire layer (ETag/If-Match, 412/304) is covered by the Phase 1.2/1.3
  controller slices; this file pins the context/changeset seam.
  """

  use Dhc.DataCase, async: true

  alias Dhc.InventoryFixtures
  alias Dhc.Inventory
  alias Dhc.MemberFixtures
  alias Dhc.Members
  alias Dhc.Repo
  alias Dhc.Settings
  alias Dhc.Waitlist
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  @actor_id Ecto.UUID.generate()

  setup do
    # The actor is a Principal so `updated_by`/`created_by` FKs resolve.
    %Dhc.Auth.Principal{id: @actor_id}
    |> Dhc.Auth.Principal.email_changeset(%{
      email: "actor-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()

    # Open the waitlist so `Waitlist.create_entry/1` is accepted.
    Repo.get_by!(Dhc.Settings.Setting, key: "waitlist_open")
    |> Ecto.Changeset.change(value: "true")
    |> Repo.update!()

    :ok
  end

  # ── Migration / column contract ───────────────────────────────────────

  describe "lock_version column" do
    test "exists on every mutable table with null: false, default: 1" do
      expected_tables = ~w(
        inventory_items
        containers
        equipment_categories
        club_activities
        club_activity_registrations
        waitlist
        user_profiles
        member_profiles
        settings
      )

      columns = columns_with_defaults()

      Enum.each(expected_tables, fn table ->
        assert table in columns
      end)
    end

    test "excludes payment, refund, and workflow tables" do
      columns = columns_with_defaults()

      Enum.each(
        ~w(club_activity_payment_attempts club_activity_refunds durable_workshop_payment_workflows durable_workshop_refund_workflows),
        fn table ->
          refute table in columns
        end
      )
    end

    test "existing rows default to 1" do
      workshop = WorkshopFixtures.workshop_fixture()
      assert %{lock_version: 1} = Repo.reload!(workshop)
    end
  end

  # ── Inventory: item (Multi update + move + maintenance commands) ──────

  describe "inventory item optimistic lock" do
    setup do
      category = insert_category(name: "Cat")
      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)

      %{item_id: item_id, container_id: container_id}
    end

    test "update_item bumps lock_version and threads through the Multi", %{
      item_id: item_id
    } do
      assert {:ok, item} = Inventory.get_item(item_id)
      assert item.lock_version == 1

      assert {:ok, updated} = Inventory.update_item(item_id, %{"notes" => "first"}, @actor_id)
      assert updated.lock_version == 2

      # A second update on the fresh read bumps again.
      assert {:ok, updated_again} =
               Inventory.update_item(item_id, %{"notes" => "second"}, @actor_id)

      assert updated_again.lock_version == 3
    end

    test "stale item update raises StaleEntryError", %{item_id: item_id} do
      assert {:ok, stale} = Inventory.get_item(item_id)
      assert {:ok, _} = Inventory.update_item(item_id, %{"notes" => "winner"}, @actor_id)

      assert_raise Ecto.StaleEntryError, fn ->
        stale
        |> Ecto.Changeset.change(notes: "loser")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end

    test "move_item bumps the version", %{item_id: item_id, container_id: container_id} do
      assert {:ok, moved} =
               Inventory.move_item(
                 item_id,
                 %{"containerId" => container_id, "notes" => "mv"},
                 @actor_id
               )

      assert moved.lock_version == 2
    end

    test "set_item_maintenance bumps the version", %{item_id: item_id} do
      assert {:ok, item} =
               Inventory.set_item_maintenance(item_id, %{"outForMaintenance" => true}, @actor_id)

      assert item.lock_version == 2
    end
  end

  # ── Inventory: categories & containers ────────────────────────────────

  describe "category optimistic lock" do
    test "update_category bumps the version and stale writes raise" do
      {:ok, category} = Inventory.create_category(%{"name" => "Locks"})
      assert category.lock_version == 1

      assert {:ok, updated} = Inventory.update_category(category.id, %{"description" => "d"})
      assert updated.lock_version == 2

      assert_raise Ecto.StaleEntryError, fn ->
        category
        |> Ecto.Changeset.change(description: "stale")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end
  end

  describe "container optimistic lock" do
    test "update_container bumps the version and stale writes raise" do
      assert {:ok, container} = Inventory.create_container(%{"name" => "Box"}, @actor_id)
      assert container.lock_version == 1

      assert {:ok, updated} = Inventory.update_container(container.id, %{"name" => "Crate"})
      assert updated.lock_version == 2

      assert_raise Ecto.StaleEntryError, fn ->
        container
        |> Ecto.Changeset.change(name: "stale")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end
  end

  # ── Workshops ──────────────────────────────────────────────────────────

  describe "workshop optimistic lock" do
    test "update_workshop bumps the version and stale writes raise" do
      workshop = WorkshopFixtures.workshop_fixture()
      assert workshop.lock_version == 1

      assert {:ok, updated} = Workshops.update_workshop(workshop.id, %{"title" => "Renamed"})
      assert updated.lock_version == 2

      assert_raise Ecto.StaleEntryError, fn ->
        workshop
        |> Ecto.Changeset.change(title: "stale")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end

    test "publish_workshop bumps the version" do
      workshop = WorkshopFixtures.workshop_fixture()

      assert {:ok, published} = Workshops.publish_workshop(workshop.id)
      assert published.lock_version == 2
    end

    test "cancel_workshop bumps the version" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")

      assert {:ok, cancelled} = Workshops.cancel_workshop(workshop.id, @actor_id)
      assert cancelled.lock_version == 2
    end

    test "delete_workshop archive path bumps the version" do
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()
      workshop = WorkshopFixtures.workshop_fixture()
      WorkshopFixtures.registration_fixture(workshop_id: workshop.id, member_user_id: uid)

      assert {:ok, :archived, summary} = Workshops.delete_workshop(workshop.id)
      assert is_map(summary)
      assert %{lock_version: 2} = Repo.reload!(workshop)
    end
  end

  # ── Workshop registrations (attendance command) ────────────────────────

  describe "registration optimistic lock" do
    test "update_workshop_attendance bumps the registration version" do
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()

      workshop =
        WorkshopFixtures.workshop_fixture(
          start_date:
            DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second),
          end_date: DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
          status: "published"
        )

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: uid,
          status: "confirmed"
        )

      assert {:ok, [updated]} =
               Workshops.update_workshop_attendance(workshop.id, @actor_id, [
                 %{
                   registration_id: registration.id,
                   attendance_status: "attended",
                   notes: "present"
                 }
               ])

      assert updated.lock_version == 2
    end

    test "stale registration writes raise" do
      %{auth_user_id: uid} = WorkshopFixtures.member_fixture()
      workshop = WorkshopFixtures.workshop_fixture()

      registration =
        WorkshopFixtures.registration_fixture(workshop_id: workshop.id, member_user_id: uid)

      # A fresh read succeeds and bumps the version; the pre-update struct is stale.
      fresh = Repo.reload!(registration)

      fresh
      |> Ecto.Changeset.change(status: "cancelled")
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update()

      assert %{lock_version: 2} = Repo.reload!(registration)

      assert_raise Ecto.StaleEntryError, fn ->
        registration
        |> Ecto.Changeset.change(status: "cancelled")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end
  end

  # ── Waitlist ───────────────────────────────────────────────────────────

  describe "waitlist optimistic lock" do
    test "update_entry bumps the version and stale writes raise" do
      {:ok, %{id: entry_id}} =
        Waitlist.create_entry(%{
          "email" => "lock-#{System.unique_integer([:positive])}@example.com",
          "firstName" => "Lock",
          "lastName" => "Test",
          "dateOfBirth" => "1990-01-01",
          "gender" => "man (cis)",
          "pronouns" => "he/him",
          "phoneNumber" => "+353810000000",
          "medicalConditions" => "",
          "socialMediaConsent" => "no"
        })

      assert {:ok, _} = Waitlist.update_entry(entry_id, %{"status" => "invited"})

      stale = Repo.get!(Dhc.Waitlist.WaitlistEntry, entry_id)
      assert stale.lock_version == 2

      assert_raise Ecto.StaleEntryError, fn ->
        # A struct captured at version 1 no longer matches the row.
        version_one = %{stale | lock_version: 1}

        version_one
        |> Ecto.Changeset.change(admin_notes: "stale")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end
  end

  # ── Member profiles ────────────────────────────────────────────────────

  describe "member profile optimistic lock" do
    test "update_member bumps the version on both profiles and stale writes raise" do
      member = MemberFixtures.member_fixture()

      assert {:ok, _} =
               Members.update_member(member.auth_user_id, %{
                 "firstName" => "Renamed",
                 "nextOfKinName" => "Kin"
               })

      user_profile = Repo.get!(Dhc.UserProfiles.UserProfile, member.profile_id)
      member_profile = Repo.get!(Dhc.MemberProfiles.MemberProfile, member.auth_user_id)

      assert user_profile.lock_version == 2
      assert member_profile.lock_version == 2

      assert_raise Ecto.StaleEntryError, fn ->
        # A struct captured at version 1 no longer matches the row.
        stale = %{user_profile | lock_version: 1}

        stale
        |> Ecto.Changeset.change(first_name: "stale")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end
  end

  # ── Settings ───────────────────────────────────────────────────────────

  describe "settings optimistic lock" do
    test "update bumps the version and stale writes raise" do
      # `Settings.update/2` requires the configured row to pre-exist; the
      # baseline migration seeds it, so fetch rather than re-insert.
      assert {:ok, item} = Settings.update("hema_insurance_form_link", "https://new.example.com")

      row = Repo.get_by!(Dhc.Settings.Setting, key: "hema_insurance_form_link")
      assert row.lock_version == 2
      assert item.updated_at

      assert_raise Ecto.StaleEntryError, fn ->
        # Reuse the pre-update struct as the stale read.
        stale = %{row | lock_version: row.lock_version - 1}

        stale
        |> Ecto.Changeset.change(value: "https://stale.example.com")
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp columns_with_defaults do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT table_name
      FROM information_schema.columns
      WHERE column_name = 'lock_version'
      """)

    Enum.map(rows, &hd/1)
  end

  defp insert_category(attrs) do
    attrs = Enum.into(attrs, %{})

    {:ok, category} =
      %EquipmentCategory{}
      |> Ecto.Changeset.cast(attrs, [:name, :description, :available_attributes])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  defp insert_container!(container_name \\ "Lock Container") do
    user_id = Ecto.UUID.generate()

    %Dhc.Auth.Principal{id: user_id}
    |> Dhc.Auth.Principal.email_changeset(%{
      email: "optlock-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()

    container_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        "INSERT INTO containers (id, name, created_by, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
        [Ecto.UUID.dump!(container_id), container_name, Ecto.UUID.dump!(user_id)]
      )

    container_id
  end

  defp insert_item(container_id, category_id) do
    item_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        """
        INSERT INTO inventory_items
          (id, container_id, category_id, attributes, quantity, created_at, updated_at)
        VALUES ($1, $2, $3, '{}'::jsonb, 1, NOW(), NOW())
        """,
        [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(container_id), Ecto.UUID.dump!(category_id)]
      )

    {:ok, item_id}
  end
end
