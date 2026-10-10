defmodule Dhc.Waitlist.Import.SheetImportTest do
  @moduledoc """
  ALE-376: the Waitlist spreadsheet import against sample Google Forms
  exports (`test/fixtures/waitlist_import/`).
  """

  use Dhc.DataCase, async: true

  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.Import
  alias Dhc.Waitlist.Import.Sheet
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.Waitlist.WaitlistGuardian

  @fixtures Path.expand("../../../fixtures/waitlist_import", __DIR__)
  # The sample's minors are born "01/03/2009"; the tests move that to 17
  # years before today so they stay minors whatever day the suite runs.
  defp fixture(name) do
    seventeen =
      Date.utc_today() |> Date.shift(year: -17, month: -1) |> Calendar.strftime("%d/%m/%Y")

    @fixtures |> Path.join(name) |> File.read!() |> String.replace("01/03/2009", seventeen)
  end

  describe "Sheet.parse/1" do
    test "maps the Google Forms columns into registration-shaped rows" do
      assert {:ok, [ada, niamh, oisin, duplicate, ciara, cher, dara]} =
               Sheet.parse(fixture("sample.tsv"))

      assert ada.row == 2

      assert ada.attrs == %{
               "firstName" => "Ada",
               "lastName" => "Lovelace King",
               "email" => "ada@example.com",
               "phoneNumber" => "087 000 0001",
               "dateOfBirth" => "1990-05-17",
               "medicalConditions" => "None",
               "pronouns" => "she/her",
               "socialMediaConsent" => "no",
               # 18:30:05 in Dublin in February is GMT.
               "registeredAt" => ~U[2024-02-09 18:30:05Z]
             }

      assert %{
               "guardianFirstName" => "Aoife",
               "guardianLastName" => "Byrne",
               "guardianPhoneNumber" => "087 123 4567"
             } = niamh.attrs

      assert oisin.error =~ "Guardian details \"Mary - call me\" could not be read"
      assert duplicate.error == "duplicate of row 2"

      # ISO date of birth; July is IST, so 10:00 Dublin is 09:00 UTC.
      assert ciara.attrs["dateOfBirth"] == "1985-01-01"
      assert ciara.attrs["registeredAt"] == ~U[2024-07-15 09:00:00Z]
      assert ciara.paid == %{raw: "Yes", carried_fee?: true}
      assert ciara.notes == []

      assert cher.error == "Name \"Cher\" needs a first and a last name"
      assert dara.paid == %{raw: "€80", carried_fee?: true}
      assert ada.paid == %{raw: "", carried_fee?: false}
    end

    test "reads a comma-separated export with quoted multi-line cells" do
      assert {:ok, [ada, niamh]} = Sheet.parse(fixture("sample.csv"))

      assert ada.attrs["email"] == "ada@example.com"

      assert %{
               "guardianFirstName" => "Aoife",
               "guardianLastName" => "Byrne",
               "guardianPhoneNumber" => "087 123 4567"
             } = niamh.attrs
    end

    test "refuses the whole sheet when a date is only valid month-first" do
      assert {:error, reason} = Sheet.parse(fixture("month_first.tsv"))
      assert reason =~ "month-first"
      assert reason =~ ~s(row 3 Timestamp "02/25/2024 10:00:00")
    end

    test "refuses a sheet missing a column" do
      assert {:error, reason} =
               Sheet.parse("Timestamp\tEmail address\n01/01/2024 10:00:00\ta@b.ie\n")

      assert reason =~ ~s(no "name" column)
    end

    test "reads dates day-first or ISO and never swaps an invalid day-first date" do
      assert {:ok, ~D[2024-02-03]} = Sheet.parse_date("03/02/2024")
      assert {:ok, ~D[2024-02-03]} = Sheet.parse_date("3/2/2024")
      assert {:ok, ~D[2024-02-03]} = Sheet.parse_date("2024-02-03")
      assert {:error, :month_first} = Sheet.parse_date("10/25/2026")
      assert {:error, :invalid} = Sheet.parse_date("31/31/2024")
      assert {:error, :invalid} = Sheet.parse_date("yesterday")
    end

    test "reads any non-blank Paid text as a Carried Fee and keeps it raw" do
      assert Sheet.paid("") == %{raw: "", carried_fee?: false}
      assert Sheet.paid("   ") == %{raw: "", carried_fee?: false}

      for raw <- ["Yes", "€80", "paid 80 via link", "no", "maybe later", "x"] do
        assert Sheet.paid("  #{raw} ") == %{raw: raw, carried_fee?: true}
      end
    end

    test "parses Guardian free text only when it has a name, one email and one phone" do
      assert {:ok, %{"guardianFirstName" => "Sean", "guardianLastName" => "O'Neill"}} =
               Sheet.guardian(
                 "Name: Sean O'Neill / email: sean@example.ie / phone: +353 87 765 4321"
               )

      assert {:ok, %{}} = Sheet.guardian("")
      assert {:error, _} = Sheet.guardian("Sean O'Neill +353 87 765 4321")
      assert {:error, _} = Sheet.guardian("Sean O'Neill sean@example.ie")
      assert {:error, _} = Sheet.guardian("Sean sean@example.ie 087 765 4321")
      assert {:error, _} = Sheet.guardian("A B a@example.ie b@example.ie 087 765 4321")
    end
  end

  describe "Import.import_sheet/2" do
    setup do
      # The import works while public registration is closed.
      Repo.query!("UPDATE settings SET value = 'false' WHERE key = 'waitlist_open'")
      :ok
    end

    test "imports readable rows as waiting with their Timestamp and reports the rest" do
      assert {:ok, report} = Import.import_sheet(fixture("sample.tsv"))

      refute report.dry_run
      assert Enum.map(report.imported, & &1.row) == [2, 3, 6, 8]
      assert Enum.all?(report.imported, &is_binary(&1.id))

      assert [
               %{row: 4, reason: "Guardian details" <> _},
               %{row: 5, reason: "duplicate of row 2"},
               %{row: 7, reason: "Name \"Cher\" needs a first and a last name"}
             ] = report.refused

      assert report.notes == []

      paid = Map.new(report.imported, &{&1.row, &1.paid.carried_fee?})
      assert paid == %{2 => false, 3 => false, 6 => true, 8 => true}

      lines = Import.format_report(report)
      assert ~s|  row 6 ciara@example.com: carried fee: yes (raw: "Yes")| in lines
      assert ~s|  row 8 dara@example.com: carried fee: yes (raw: "€80")| in lines
      assert "  row 2 ada@example.com" in lines

      ada = Repo.get_by!(WaitlistEntry, email: "ada@example.com")
      assert ada.status == "waiting"
      assert ada.initial_registration_date == ~U[2024-02-09 18:30:05Z]

      profile = Repo.get_by!(UserProfile, waitlist_id: ada.id)
      assert profile.gender == nil
      assert profile.social_media_consent == "no"
      assert profile.last_name == "Lovelace King"

      niamh = Repo.get_by!(WaitlistEntry, email: "niamh@example.com")
      niamh_profile = Repo.get_by!(UserProfile, waitlist_id: niamh.id)

      assert %WaitlistGuardian{first_name: "Aoife", phone_number: "087 123 4567"} =
               Repo.get_by!(WaitlistGuardian, profile_id: niamh_profile.id)

      # Paid is never a standing.
      assert Repo.get_by!(WaitlistEntry, email: "ciara@example.com").status == "waiting"
      assert Repo.aggregate(WaitlistEntry, :count) == 4
    end

    test "a dry run reports the same rows and writes nothing" do
      assert {:ok, dry} = Import.import_sheet(fixture("sample.tsv"), dry_run: true)

      assert dry.dry_run
      assert Enum.map(dry.imported, & &1.row) == [2, 3, 6, 8]
      assert Enum.all?(dry.imported, &is_nil(&1.id))
      assert Enum.map(dry.refused, & &1.row) == [4, 5, 7]
      refute Repo.exists?(WaitlistEntry)

      [summary | _] = Import.format_report(dry)
      assert summary =~ "DRY RUN (nothing written). 4 would import, 3 refused, 0 to review."
    end

    test "a month-first sheet writes nothing" do
      assert {:error, _reason} = Import.import_sheet(fixture("month_first.tsv"))
      refute Repo.exists?(WaitlistEntry)
    end

    test "re-running refuses everyone already imported" do
      {:ok, _} = Import.import_sheet(fixture("sample.tsv"))
      {:ok, again} = Import.import_sheet(fixture("sample.tsv"))

      assert again.imported == []
      assert Enum.count(again.refused, &(&1.reason == "email_on_waitlist")) == 4
    end

    test "free-text Paid values never refuse a row" do
      sheet = String.replace(fixture("sample.tsv"), "\tYes\r\n", "\tpaid 80 via link\r\n")

      {:ok, report} = Import.import_sheet(sheet)

      ciara = Enum.find(report.imported, &(&1.row == 6))
      assert ciara.paid == %{raw: "paid 80 via link", carried_fee?: true}

      assert ~s|  row 6 ciara@example.com: carried fee: yes (raw: "paid 80 via link")| in Import.format_report(
               report
             )
    end

    test "the Carried Fee extension point runs in the row's transaction, after the insert" do
      test_pid = self()

      carried_fee = fn entry_id, paid ->
        send(
          test_pid,
          {:carried_fee, entry_id, paid, Repo.in_transaction?(),
           Repo.exists?(from(w in WaitlistEntry, where: w.id == ^entry_id))}
        )

        :ok
      end

      {:ok, report} =
        Import.import_sheet(fixture("sample.tsv"), carried_fee: carried_fee)

      dara = Enum.find(report.imported, &(&1.row == 8))

      assert_received {:carried_fee, id, %{carried_fee?: true, raw: "€80"}, true, true}
                      when id == dara.id
    end

    test "a failing Carried Fee refuses the row and rolls its person back" do
      carried_fee = fn _entry_id, paid ->
        if paid.carried_fee?, do: {:error, :carried_fee_failed}, else: :ok
      end

      {:ok, report} =
        Import.import_sheet(fixture("sample.tsv"), carried_fee: carried_fee)

      assert Enum.map(report.imported, & &1.row) == [2, 3]
      assert %{reason: "carried_fee_failed"} = Enum.find(report.refused, &(&1.row == 8))
      refute Repo.get_by(WaitlistEntry, email: "dara@example.com")
    end

    test "a first name over 40 characters is refused, not truncated" do
      long = String.duplicate("a", 41)

      sheet =
        fixture("sample.tsv")
        |> String.replace("Ada  Lovelace King", "#{long} Lovelace")

      {:ok, report} = Import.import_sheet(sheet)

      assert %{row: 2, reason: "first_name: should be at most 40 character(s)"} =
               Enum.find(report.refused, &(&1.row == 2))
    end
  end
end
