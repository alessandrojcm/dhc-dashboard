defmodule Dhc.ConditionalWriteRaceTest do
  @moduledoc """
  Regression coverage for the read-to-write window behind conditional writes.

  The telemetry barrier pauses the writer *after* its initial SELECT has
  completed but before `Repo.get/2` returns to the context.  The competing
  transaction can therefore commit an optimistic update before the context
  attempts its write.  This is deliberately stronger than passing an already
  stale If-Match value to the context.
  """
  use Dhc.DataCase, async: false

  import Ecto.Query

  alias Dhc.Inventory
  alias Dhc.Inventory.{Container, EquipmentCategory}
  alias Dhc.MemberFixtures
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Members
  alias Dhc.Repo
  alias Dhc.Settings
  alias Dhc.Settings.Setting
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops
  alias Dhc.Workshops.{Registration, Workshop}
  alias Ecto.Adapters.SQL.Sandbox

  test "category update and delete return the current entity after a read/write race" do
    category = unboxed(fn -> Repo.insert!(%EquipmentCategory{name: unique_name("category")}) end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(c in EquipmentCategory, where: c.id == ^category.id))
      end)
    end)

    assert {:error, {:version_precondition_failed, %{lock_version: 2} = current}} =
             race_after_read(
               "equipment_categories",
               fn ->
                 Inventory.update_category(category.id, %{"description" => "writer"},
                   expected_lock_version: 1
                 )
               end,
               fn -> bump!(EquipmentCategory, category.id, description: "competitor") end
             )

    assert current.id == category.id

    assert {:error, {:version_precondition_failed, %{lock_version: 3}}} =
             race_after_read(
               "equipment_categories",
               fn ->
                 Inventory.delete_category(category.id, expected_lock_version: 2)
               end,
               fn -> bump!(EquipmentCategory, category.id, description: "competitor again") end
             )
  end

  test "container update and delete return the current entity after a read/write race" do
    actor_id = Ecto.UUID.generate()

    unboxed(fn ->
      {:ok, _} =
        Dhc.Auth.register_principal_with_id(actor_id, %{email: "#{actor_id}@example.com"})
    end)

    container =
      unboxed(fn ->
        Repo.insert!(%Container{
          id: Ecto.UUID.generate(),
          name: unique_name("container"),
          created_by: actor_id
        })
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(c in Container, where: c.id == ^container.id))
        Repo.query!("DELETE FROM principals WHERE id = $1", [Ecto.UUID.dump!(actor_id)])
      end)
    end)

    assert {:error, {:version_precondition_failed, %{lock_version: 2}}} =
             race_after_read(
               "containers",
               fn ->
                 Inventory.update_container(container.id, %{"name" => "writer"},
                   expected_lock_version: 1
                 )
               end,
               fn -> bump!(Container, container.id, name: "competitor") end
             )

    assert {:error, {:version_precondition_failed, %{lock_version: 3}}} =
             race_after_read(
               "containers",
               fn ->
                 Inventory.delete_container(container.id, expected_lock_version: 2)
               end,
               fn -> bump!(Container, container.id, name: "competitor again") end
             )
  end

  test "a vanished category remains not found after its precondition read" do
    category = unboxed(fn -> Repo.insert!(%EquipmentCategory{name: unique_name("vanished")}) end)

    assert {:error, :not_found} =
             race_after_read(
               "equipment_categories",
               fn ->
                 Inventory.delete_category(category.id, expected_lock_version: 1)
               end,
               fn ->
                 unboxed(fn -> Repo.delete!(Repo.get!(EquipmentCategory, category.id)) end)
               end
             )
  end

  test "settings returns the current item after a read/write race" do
    key = "hema_insurance_form_link"
    original = unboxed(fn -> Repo.get_by!(Setting, key: key) end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.update!(
          Ecto.Changeset.change(Repo.get_by!(Setting, key: key), value: original.value)
        )
      end)
    end)

    assert {:error, {:version_precondition_failed, %{key: ^key, lock_version: current_version}}} =
             race_after_read(
               "settings",
               fn ->
                 Settings.update(key, "https://writer.example.com",
                   expected_lock_version: original.lock_version
                 )
               end,
               fn -> bump!(Setting, original.id, value: "https://competitor.example.com") end
             )

    assert current_version > original.lock_version
  end

  test "waitlist update returns the current entry after a read/write race" do
    original_open = unboxed(fn -> Repo.get_by!(Setting, key: "waitlist_open") end)

    unboxed(fn ->
      Repo.update!(Ecto.Changeset.change(original_open, value: "true"))
    end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.update!(
          Ecto.Changeset.change(Repo.get_by!(Setting, key: "waitlist_open"),
            value: original_open.value
          )
        )
      end)
    end)

    entry =
      unboxed(fn ->
        {:ok, %{id: id}} = Waitlist.create_entry(waitlist_attrs())
        Repo.get!(WaitlistEntry, id)
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(p in UserProfile, where: p.waitlist_id == ^entry.id))
        Repo.delete_all(from(e in WaitlistEntry, where: e.id == ^entry.id))
      end)
    end)

    assert {:error, {:version_precondition_failed, %{id: id, lock_version: 2}}} =
             race_after_read(
               "waitlist",
               fn ->
                 Waitlist.update_entry(entry.id, %{"adminNotes" => "writer"},
                   expected_lock_version: 1
                 )
               end,
               fn -> bump!(WaitlistEntry, entry.id, admin_notes: "competitor") end
             )

    assert id == entry.id
  end

  test "member aggregate updates roll back the user profile when member profile becomes stale" do
    member = unboxed(fn -> MemberFixtures.member_fixture() end)
    on_exit(fn -> delete_member_fixture(member) end)

    user_before = unboxed(fn -> Repo.get!(UserProfile, member.profile_id) end)

    assert {:error, {:version_precondition_failed, %{lock_version: 2}}} =
             race_after_read(
               "member_profiles",
               fn ->
                 Members.update_member(
                   member.auth_user_id,
                   %{
                     "firstName" => "Writer",
                     "nextOfKinName" => "Writer Kin"
                   },
                   expected_lock_version: 1
                 )
               end,
               fn ->
                 bump!(MemberProfile, member.auth_user_id, next_of_kin_name: "Competitor Kin")
               end
             )

    user_after = unboxed(fn -> Repo.get!(UserProfile, member.profile_id) end)
    member_after = unboxed(fn -> Repo.get!(MemberProfile, member.auth_user_id) end)
    assert user_after.first_name == user_before.first_name
    assert user_after.lock_version == user_before.lock_version
    assert member_after.next_of_kin_name == "Competitor Kin"
    assert member_after.lock_version == 2
  end

  test "workshop update returns the current summary after a read/write race" do
    workshop = unboxed(fn -> WorkshopFixtures.workshop_fixture() end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(w in Workshop, where: w.id == ^workshop.id)) end)
    end)

    assert {:error, {:version_precondition_failed, %{id: id, lock_version: 2}}} =
             race_after_read(
               "club_activities",
               fn ->
                 Workshops.update_workshop(workshop.id, %{"title" => "Writer"},
                   expected_lock_version: 1
                 )
               end,
               fn -> bump!(Workshop, workshop.id, title: "Competitor") end
             )

    assert id == workshop.id
  end

  test "registration cancellation returns the current registration after a read/write race" do
    {workshop, member, registration} = unboxed(&member_registration_fixture/0)
    on_exit(fn -> delete_member_registration_fixture(workshop, member, registration) end)

    assert {:error, {:version_precondition_failed, %{id: id, lock_version: 2}}} =
             race_after_read(
               "club_activity_registrations",
               fn ->
                 Workshops.cancel_member_registration(workshop.id, member.auth_user_id,
                   expected_lock_version: 1
                 )
               end,
               fn -> bump!(Registration, registration.id, attendance_notes: "competitor") end
             )

    assert id == registration.id
  end

  test "attendance batch leaves earlier rows untouched when a later registration is stale" do
    {workshop, first_member, first, second_member, second} = unboxed(&attendance_fixture/0)

    on_exit(fn ->
      delete_attendance_fixture(workshop, first_member, first, second_member, second)
    end)

    updates = [
      %{registration_id: first.id, attendance_status: "attended", notes: "first"},
      %{registration_id: second.id, attendance_status: "no_show", notes: "second"}
    ]

    unboxed(fn -> bump!(Registration, second.id, attendance_notes: "competitor") end)

    updates =
      List.update_at(updates, 1, fn update ->
        Map.put(update, :expected_lock_version, 1)
      end)

    assert {:error, {:version_precondition_failed, %{id: id, lock_version: 2}}} =
             unboxed(fn ->
               Workshops.update_workshop_attendance(
                 workshop.id,
                 first_member.auth_user_id,
                 updates
               )
             end)

    assert id == second.id
    first_after = unboxed(fn -> Repo.get!(Registration, first.id) end)
    assert first_after.attendance_status == "pending"
    assert first_after.attendance_notes == nil
    assert first_after.lock_version == 1
  end

  defp race_after_read(table, write_fun, competing_write, opts \\ []) do
    test_process = self()

    supervisor =
      start_supervised!(
        {Task.Supervisor, name: {:global, {__MODULE__, System.unique_integer([:positive])}}}
      )

    occurrence = Keyword.get(opts, :occurrence, 1)
    query_fragment = Keyword.get(opts, :query_fragment, "")

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(test_process, {:writer_ready, self()})
        receive do: (:start -> unboxed(write_fun))
      end)

    assert_receive {:writer_ready, writer_pid}
    handler_id = "conditional-write-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:dhc, :repo, :query],
        &query_barrier/4,
        {test_process, writer_pid, table, occurrence, query_fragment}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    send(writer_pid, :start)
    assert_receive {:initial_read_complete, ^writer_pid}
    unboxed(competing_write)
    send(writer_pid, :continue)
    Task.await(writer)
  end

  defp query_barrier(
         _event,
         _measurements,
         metadata,
         {test_process, writer_pid, table, occurrence, query_fragment}
       ) do
    query = metadata.query || ""

    if self() == writer_pid and String.contains?(query, "FROM \"#{table}\"") and
         String.contains?(query, query_fragment) do
      count = Process.get({__MODULE__, table}, 0) + 1
      Process.put({__MODULE__, table}, count)

      if count == occurrence do
        send(test_process, {:initial_read_complete, writer_pid})
        receive do: (:continue -> :ok)
      end
    end
  end

  defp bump!(schema, id, changes) do
    schema
    |> Repo.get!(id)
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update!()
  end

  defp member_registration_fixture do
    member = MemberFixtures.member_fixture()
    workshop = WorkshopFixtures.workshop_fixture(status: "published", refund_days: 0)

    registration =
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: member.auth_user_id,
        status: "confirmed"
      )

    {workshop, member, registration}
  end

  defp attendance_fixture do
    workshop =
      WorkshopFixtures.workshop_fixture(
        status: "published",
        start_date: DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
      )

    first_member = MemberFixtures.member_fixture()
    second_member = MemberFixtures.member_fixture()

    first =
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: first_member.auth_user_id,
        status: "confirmed"
      )

    second =
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: second_member.auth_user_id,
        status: "confirmed"
      )

    {workshop, first_member, first, second_member, second}
  end

  defp delete_member_registration_fixture(workshop, member, registration) do
    unboxed(fn ->
      Repo.delete_all(from(r in Registration, where: r.id == ^registration.id))
      Repo.delete_all(from(w in Workshop, where: w.id == ^workshop.id))
    end)

    delete_member_fixture(member)
  end

  defp delete_attendance_fixture(workshop, first_member, first, second_member, second) do
    unboxed(fn ->
      Repo.delete_all(from(r in Registration, where: r.id in [^first.id, ^second.id]))
      Repo.delete_all(from(w in Workshop, where: w.id == ^workshop.id))
    end)

    delete_member_fixture(first_member)
    delete_member_fixture(second_member)
  end

  defp delete_member_fixture(member) do
    unboxed(fn ->
      Repo.delete_all(from(m in MemberProfile, where: m.id == ^member.auth_user_id))
      Repo.delete_all(from(p in UserProfile, where: p.id == ^member.profile_id))
      Repo.query!("DELETE FROM principals WHERE id = $1", [Ecto.UUID.dump!(member.auth_user_id)])
    end)
  end

  defp waitlist_attrs do
    %{
      "email" => "race-#{System.unique_integer([:positive])}@example.com",
      "firstName" => "Race",
      "lastName" => "Entry",
      "dateOfBirth" => "1990-01-01",
      "gender" => "man (cis)",
      "pronouns" => "he/him",
      "phoneNumber" => "+353810000000",
      "medicalConditions" => "",
      "socialMediaConsent" => "no"
    }
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
