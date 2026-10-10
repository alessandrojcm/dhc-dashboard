defmodule Dhc.Waitlist.RegistrationTest do
  @moduledoc """
  ALE-376: Waitlist re-entry and duplicate-proof registration. Public
  registration refuses colliding emails silently (the HTTP edge hides the
  reason, see `DhcWeb.WaitlistControllerTest`), the staff "add a new person"
  path returns the reason, and `restore/2` honours a 3-month window.
  """

  use Dhc.DataCase, async: true

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-09 12:00:00Z]

  describe "add_person/2 (staff path)" do
    setup do
      set_waitlist_open(false)
      :ok
    end

    test "creates a waiting entry while registration is closed, prioritised by its creation date" do
      assert {:ok, %{id: id, status: "waiting"}} =
               Waitlist.add_person(payload("New@Example.com"), now: @now)

      entry = Repo.get!(WaitlistEntry, id)
      assert entry.email == "new@example.com"
      assert entry.initial_registration_date == @now
      assert Repo.get_by!(UserProfile, waitlist_id: id).first_name == "Ada"
    end

    for standing <- Dhc.Waitlist.Standing.statuses() do
      @standing standing
      test "refuses an email on the Waitlist as #{standing} with :email_on_waitlist" do
        insert_entry!("taken@example.com", @standing)

        assert {:error, :email_on_waitlist} = Waitlist.add_person(payload("Taken@example.com"))
      end
    end

    test "refuses a Principal's email with :email_is_principal" do
      {:ok, _} =
        Dhc.Auth.register_principal_with_id(Ecto.UUID.generate(), %{email: "m@example.com"})

      assert {:error, :email_is_principal} = Waitlist.add_person(payload("M@example.com"))
    end

    test "refuses an email with a pending Invitation with :email_has_pending_invitation" do
      {:ok, _} =
        Dhc.Invitations.Repository.insert_pending_invitation(
          %{"email" => "invited@example.com", "dateOfBirth" => "1990-01-01"},
          nil,
          nil
        )

      assert {:error, :email_has_pending_invitation} =
               Waitlist.add_person(payload("invited@example.com"))
    end

    test "validates the details like registration, first name included" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Waitlist.add_person(%{
                 payload("long@example.com")
                 | "firstName" => String.duplicate("a", 41)
               })

      assert {"should be at most %{count} character(s)", _} = changeset.errors[:first_name]

      assert {:error, :invalid_payload} =
               Waitlist.add_person(Map.delete(payload("x@example.com"), "email"))

      refute Repo.exists?(WaitlistEntry)
    end

    test "joins the caller's transaction and rolls back with it" do
      assert {:error, :caller_failed} =
               Repo.transaction(fn ->
                 {:ok, _} = Waitlist.add_person(payload("inside@example.com"))
                 Repo.rollback(:caller_failed)
               end)

      refute Repo.get_by(WaitlistEntry, email: "inside@example.com")
    end

    test "a refusal inside the caller's transaction writes nothing and leaves it usable" do
      insert_entry!("taken@example.com", "waiting")

      assert {:ok, :still_usable} =
               Repo.transaction(fn ->
                 {:error, :email_on_waitlist} = Waitlist.add_person(payload("taken@example.com"))
                 :still_usable
               end)

      assert Repo.aggregate(WaitlistEntry, :count) == 1
    end
  end

  describe "create_entry/2 (public registration)" do
    setup do
      set_waitlist_open(true)
      :ok
    end

    test "returns the refusal reason to Phoenix callers and writes nothing" do
      insert_entry!("waiting@example.com", "waiting")

      assert {:error, :email_on_waitlist} = Waitlist.create_entry(payload("waiting@example.com"))
      assert Repo.aggregate(WaitlistEntry, :count) == 1
    end

    test "reopens a removed entry at the back of the queue" do
      removed = insert_entry!("back@example.com", "removed", ~U[2025-01-01 00:00:00Z])

      assert {:ok, %{id: id, status: "waiting"}} =
               Waitlist.create_entry(payload("back@example.com"), now: @now)

      assert id == removed.id
      entry = Repo.get!(WaitlistEntry, id)
      assert entry.status == "waiting"
      assert entry.initial_registration_date == @now
      assert entry.removed_at == nil
    end

    test "a removed email that is now a Principal's stays refused" do
      insert_entry!("joined-elsewhere@example.com", "removed")

      {:ok, _} =
        Dhc.Auth.register_principal_with_id(Ecto.UUID.generate(), %{
          email: "joined-elsewhere@example.com"
        })

      assert {:error, :email_is_principal} =
               Waitlist.create_entry(payload("joined-elsewhere@example.com"))

      assert Repo.get_by!(WaitlistEntry, email: "joined-elsewhere@example.com").status ==
               "removed"
    end
  end

  describe "restore/2" do
    test "restores within 3 months of removal, keeping the original date" do
      entry = insert_entry!("r@example.com", "removed", ~U[2025-06-01 00:00:00Z])
      set_removed_at(entry, ~U[2026-07-09 12:00:00Z])

      assert {:ok, %{status: "waiting", removed_at: nil}} = Waitlist.restore(entry.id, now: @now)

      assert Repo.get!(WaitlistEntry, entry.id).initial_registration_date ==
               ~U[2025-06-01 00:00:00Z]
    end

    test "refuses once 3 months have passed" do
      entry = insert_entry!("late@example.com", "removed")
      set_removed_at(entry, ~U[2026-07-09 11:59:59Z])

      assert {:error, :restore_window_passed} = Waitlist.restore(entry.id, now: @now)
      assert Repo.get!(WaitlistEntry, entry.id).status == "removed"
    end

    test "refuses an entry that is not removed, and a missing one" do
      entry = insert_entry!("w@example.com", "attended")

      assert {:error, :not_removed} = Waitlist.restore(entry.id)
      assert {:error, :not_found} = Waitlist.restore(Ecto.UUID.generate())
      assert {:error, :not_found} = Waitlist.restore("not-a-uuid")
    end

    test "restorable?/2 is the calendar-month window" do
      assert Waitlist.restorable?(~U[2026-07-09 12:00:00Z], @now)
      refute Waitlist.restorable?(~U[2026-07-09 11:59:59Z], @now)
    end
  end

  defp payload(email) do
    %{
      "firstName" => "Ada",
      "lastName" => "Lovelace",
      "email" => email,
      "phoneNumber" => "+353 1 000 0000",
      "dateOfBirth" => Date.utc_today() |> Date.add(-20 * 365) |> Date.to_iso8601(),
      "gender" => "woman (cis)",
      "medicalConditions" => ""
    }
  end

  defp insert_entry!(email, status, registered_at \\ ~U[2026-01-01 00:00:00Z]) do
    entry =
      Repo.insert!(%WaitlistEntry{
        email: email,
        status: status,
        removed_at: if(status == "removed", do: DateTime.truncate(DateTime.utc_now(), :second)),
        initial_registration_date: registered_at,
        last_status_change: registered_at
      })

    Repo.insert!(%UserProfile{
      first_name: "Old",
      last_name: "Person",
      is_active: false,
      date_of_birth: ~D[1990-01-01],
      gender: "other",
      phone_number: "+353 1 000 0000",
      social_media_consent: "no",
      waitlist_id: entry.id
    })

    entry
  end

  defp set_removed_at(entry, removed_at) do
    Repo.update_all(from(w in WaitlistEntry, where: w.id == ^entry.id),
      set: [removed_at: removed_at]
    )
  end

  defp set_waitlist_open(open?) do
    value = if open?, do: "true", else: "false"
    Repo.query!("UPDATE settings SET value = $1 WHERE key = 'waitlist_open'", [value])
  end
end
