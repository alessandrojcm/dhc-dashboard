defmodule Dhc.Waitlist.ImportTest do
  use Dhc.DataCase, async: true

  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.Import
  alias Dhc.Waitlist.WaitlistEntry

  # A sample of spreadsheet rows already mapped to the registration shape.
  @rows [
    %{
      "firstName" => "Aoife",
      "lastName" => "Byrne",
      "email" => "Aoife@Example.com",
      "phoneNumber" => "+353 87 123 4567",
      "dateOfBirth" => "1990-05-17",
      "gender" => "woman (cis)",
      "medicalConditions" => "",
      "registeredAt" => "2024-02-01"
    },
    # Duplicate of the first row: refused, not dropped.
    %{
      "firstName" => "Aoife",
      "lastName" => "Byrne",
      "email" => "aoife@example.com",
      "phoneNumber" => "+353 87 123 4567",
      "dateOfBirth" => "1990-05-17",
      "gender" => "woman (cis)",
      "medicalConditions" => "",
      "registeredAt" => "2024-03-01"
    },
    # First name over the Intake Email placeholder maximum.
    %{
      "firstName" => String.duplicate("a", 41),
      "lastName" => "Long",
      "email" => "long@example.com",
      "phoneNumber" => "+353 87 000 0000",
      "dateOfBirth" => "1990-05-17",
      "gender" => "other",
      "medicalConditions" => ""
    },
    # A minor without guardian details.
    %{
      "firstName" => "Young",
      "lastName" => "Person",
      "email" => "young@example.com",
      "phoneNumber" => "+353 87 000 0001",
      "dateOfBirth" => Date.utc_today() |> Date.shift(year: -17) |> Date.to_iso8601(),
      "gender" => "other",
      "medicalConditions" => "",
      "registeredAt" => "2024-04-01T10:30:00Z"
    },
    %{
      "firstName" => "Ciara",
      "lastName" => "Walsh",
      "email" => "ciara@example.com",
      "phoneNumber" => "+353 87 000 0002",
      "dateOfBirth" => "1985-01-01",
      "gender" => "woman (cis)",
      "medicalConditions" => "Asthma",
      "registeredAt" => "2023-11-15T09:00:00Z"
    },
    # The email belongs to a Member.
    %{
      "firstName" => "Mem",
      "lastName" => "Ber",
      "email" => "member@example.com",
      "phoneNumber" => "+353 87 000 0003",
      "dateOfBirth" => "1985-01-01",
      "gender" => "other",
      "medicalConditions" => ""
    }
  ]

  setup do
    # The import works while public registration is closed.
    Repo.query!("UPDATE settings SET value = 'false' WHERE key = 'waitlist_open'")

    {:ok, _} =
      Dhc.Auth.register_principal_with_id(Ecto.UUID.generate(), %{email: "member@example.com"})

    :ok
  end

  test "imports valid rows with their spreadsheet priority and reports every refused row" do
    result = Import.run(@rows, first_row: 2, now: ~U[2026-10-09 12:00:00Z])

    assert Enum.map(result.imported, &{&1.row, &1.email}) == [
             {2, "Aoife@Example.com"},
             {6, "ciara@example.com"}
           ]

    assert [
             %{row: 3, reason: "email_on_waitlist"},
             %{row: 4, reason: "first_name: should be at most 40 character(s)"},
             %{row: 5, reason: "under 18 with no Guardian details"},
             %{row: 7, reason: "email_is_principal"}
           ] = result.refused

    assert length(result.imported) + length(result.refused) == length(@rows)

    aoife = Repo.get_by!(WaitlistEntry, email: "aoife@example.com")
    assert aoife.status == "waiting"
    assert aoife.initial_registration_date == ~U[2024-02-01 00:00:00Z]

    ciara = Repo.get_by!(WaitlistEntry, email: "ciara@example.com")
    assert ciara.initial_registration_date == ~U[2023-11-15 09:00:00Z]
    assert Repo.get_by!(UserProfile, waitlist_id: ciara.id).medical_conditions == "Asthma"

    assert Repo.aggregate(WaitlistEntry, :count) == 2
  end

  test "re-running the import imports nothing twice" do
    Import.run(@rows)
    again = Import.run(@rows)

    assert again.imported == []
    assert length(again.refused) == length(@rows)
    assert Repo.aggregate(WaitlistEntry, :count) == 2
  end

  test "a row without a registration date takes the import time" do
    [row | _] = @rows

    %{imported: [%{id: id}]} =
      Import.run([Map.delete(row, "registeredAt")], now: ~U[2026-10-09 12:00:00Z])

    assert Repo.get!(WaitlistEntry, id).initial_registration_date == ~U[2026-10-09 12:00:00Z]
  end

  test "refuses an unreadable registration date" do
    [row | _] = @rows

    assert %{imported: [], refused: [%{row: 1, reason: "invalid_registered_at"}]} =
             Import.run([%{row | "registeredAt" => "last spring"}])
  end
end
