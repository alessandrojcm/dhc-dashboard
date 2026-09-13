defmodule Dhc.E2EHarnessMaintenanceTest do
  @moduledoc """
  ALE-288 IMPL-04: round-trip for the frozen `inventoryMaintenance` /
  `inventoryArchive` scenarios plus the `reminderState` flag.

  Seeds through `Dhc.E2EHarness` on top of `inventoryStructure` +
  `inventoryItem` (ids, never names): open maintenance carries the reason
  operator-side while the member catalog shows only the generic reason;
  closed maintenance returns the item to available; archive hides the
  catalog row while own-loan history keeps its snapshot; reminder flags pin
  exactly one owed occurrence per contract. Every seed deletes per contract
  (periods end-but-never-delete, archive restores, loans + ledger rows
  hard-delete, notifications untouched).
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.E2EHarness
  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.LoanReminders
  alias Dhc.Repo

  test "open maintenance blocks requests and leaks no notes to members" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("maint-open-actor-#{uniq}")
    borrower_id = principal_id!("maint-open-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)

    result =
      E2EHarness.seed("inventoryMaintenance", %{
        "preset" => "open",
        "itemId" => item.itemId,
        "reason" => "Cracked guard — quarantining until the armoury checks it",
        "operatorActorId" => actor_id
      })

    assert Enum.sort(Map.keys(result)) == [
             :endedBy,
             :itemId,
             :open,
             :periodId,
             :reason,
             :slug,
             :startedBy
           ]

    assert result.open == true
    assert result.itemId == item.itemId
    assert result.slug == item.slug
    assert result.reason == "Cracked guard — quarantining until the armoury checks it"
    assert result.startedBy == actor_id
    assert result.endedBy == nil

    # Operator viewer carries the reason; member catalog carries only the
    # generic reason with no reason text, dates, or attribution.
    {:ok, operator_item} = Inventory.resolve_operator_item(item.itemId)
    assert operator_item.availability == %{available?: false, status: :maintenance}

    {:ok, catalog_row} = Inventory.resolve_catalog_item(item.slug)
    assert catalog_row.availability == %{available?: false, reason: :maintenance}
    refute Map.has_key?(catalog_row, :container)
    refute Map.has_key?(catalog_row, :notes)
    assert catalog_row.label == operator_item.label

    # Member requests surface the generic refusal.
    assert {:error, :item_unavailable} =
             Inventory.request_loan(
               item.itemId,
               %{"startsOn" => Date.to_iso8601(ClubCalendar.today()), "dueOn" => due_in(7)},
               borrower_id
             )

    # Cleanup ends the period; the item stays non-deletable (retained history).
    assert :ok = E2EHarness.delete_fixture("inventoryMaintenance", result.periodId)

    {:ok, reopened} = Inventory.resolve_operator_item(item.itemId)
    assert reopened.availability == %{available?: true, status: :available}

    assert [%{open?: false}] = Inventory.list_operator_item_maintenance_periods(item.itemId)
  end

  test "open maintenance rejects pending requests with the system note" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("maint-reject-actor-#{uniq}")
    borrower_id = principal_id!("maint-reject-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)

    loan =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "requested",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id
      })

    assert loan.status == "requested"

    maintenance =
      E2EHarness.seed("inventoryMaintenance", %{
        "preset" => "open",
        "itemId" => item.itemId,
        "reason" => "Blunt edge — pulling for sharpening",
        "operatorActorId" => actor_id
      })

    assert maintenance.open == true

    {:ok, rejected} = Inventory.get_operator_loan(loan.loanId)
    assert rejected.status == "rejected"

    assert rejected.decision_note ==
             "Rejected automatically: the item went into maintenance."

    assert :ok = E2EHarness.delete_fixture("inventoryMaintenance", maintenance.periodId)
    assert :ok = E2EHarness.delete_fixture("inventoryLoan", loan.loanId)
  end

  test "live loan blocks maintenance and archive with :loan_active" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("maint-block-actor-#{uniq}")
    borrower_id = principal_id!("maint-block-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)

    loan =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "approved",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "operatorActorId" => actor_id
      })

    assert {:error, :loan_active} =
             E2EHarness.seed("inventoryMaintenance", %{
               "preset" => "open",
               "itemId" => item.itemId,
               "reason" => "Should be blocked",
               "operatorActorId" => actor_id
             })

    assert {:error, :loan_active} =
             E2EHarness.seed("inventoryArchive", %{
               "itemId" => item.itemId,
               "reason" => "Should be blocked",
               "operatorActorId" => actor_id
             })

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", loan.loanId)
  end

  test "closed maintenance returns the item to available and retains history" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("maint-closed-actor-#{uniq}")
    item = seed_item!(actor_id, uniq)

    result =
      E2EHarness.seed("inventoryMaintenance", %{
        "preset" => "closed",
        "itemId" => item.itemId,
        "reason" => "Annual inspection",
        "endNote" => "Passed — back in circulation",
        "operatorActorId" => actor_id
      })

    assert result.open == false
    assert result.reason == "Annual inspection"
    assert result.startedBy == actor_id
    assert result.endedBy == actor_id

    {:ok, operator_item} = Inventory.resolve_operator_item(item.itemId)
    assert operator_item.availability == %{available?: true, status: :available}

    {:ok, catalog_row} = Inventory.resolve_catalog_item(item.slug)
    assert catalog_row.availability == %{available?: true, reason: :available}

    [period] = Inventory.list_operator_item_maintenance_periods(item.itemId)
    assert period.open? == false
    assert period.end_note == "Passed — back in circulation"

    # Closed periods are retained: cleanup is a no-op, the item stays
    # non-deletable and archives on item cleanup.
    assert :ok = E2EHarness.delete_fixture("inventoryMaintenance", result.periodId)
    assert [%{open?: false}] = Inventory.list_operator_item_maintenance_periods(item.itemId)
  end

  test "archive hides from catalog but preserves own-loan history" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("arch-actor-#{uniq}")
    borrower_id = principal_id!("arch-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)

    loan =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "returned",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "operatorActorId" => actor_id
      })

    result =
      E2EHarness.seed("inventoryArchive", %{
        "itemId" => item.itemId,
        "reason" => "Retired — guard crack beyond repair",
        "operatorActorId" => actor_id
      })

    assert Enum.sort(Map.keys(result)) == [
             :archived,
             :archivedBy,
             :catalogHidden,
             :historyKept,
             :itemId,
             :slug
           ]

    assert result.archived == true
    assert result.archivedBy == actor_id
    assert result.catalogHidden == true
    assert result.historyKept == true

    # Member catalog answers :not_found; the operator viewer shows archived
    # (outranking maintenance/loan in projection precedence).
    assert {:error, :not_found} = Inventory.resolve_catalog_item(item.slug)

    {:ok, operator_item} = Inventory.resolve_operator_item(item.itemId)
    assert operator_item.availability == %{available?: false, status: :archived}

    # Own-loan history keeps the slug/label snapshot readable.
    {:ok, own_loan} = Inventory.get_own_loan(loan.loanId, borrower_id)
    assert own_loan.item_slug == item.slug
    assert is_binary(own_loan.item_label) and own_loan.item_label != ""

    # Already-archived is a no-op success (idempotent).
    again =
      E2EHarness.seed("inventoryArchive", %{
        "itemId" => item.itemId,
        "operatorActorId" => actor_id
      })

    assert again.archived == true
    assert again.catalogHidden == true

    # Cleanup restores; the item is never hard-deleted.
    assert :ok = E2EHarness.delete_fixture("inventoryArchive", item.itemId)
    {:ok, restored} = Inventory.resolve_operator_item(item.itemId)
    assert restored.archived_at == nil

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", loan.loanId)
  end

  test "archive closes an open period atomically" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("arch-atomic-actor-#{uniq}")
    item = seed_item!(actor_id, uniq)

    maintenance =
      E2EHarness.seed("inventoryMaintenance", %{
        "preset" => "open",
        "itemId" => item.itemId,
        "reason" => "Pre-retirement inspection",
        "operatorActorId" => actor_id
      })

    assert maintenance.open == true

    archived =
      E2EHarness.seed("inventoryArchive", %{
        "itemId" => item.itemId,
        "reason" => "Retired",
        "operatorActorId" => actor_id
      })

    assert archived.archived == true

    [period] = Inventory.list_operator_item_maintenance_periods(item.itemId)
    assert period.open? == false
    assert period.end_note == "Archived: Retired"

    assert :ok = E2EHarness.delete_fixture("inventoryArchive", item.itemId)
  end

  test "reminderState preDue owes exactly one pre_due occurrence" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("rem-predue-actor-#{uniq}")
    borrower_id = principal_id!("rem-predue-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)
    today = ClubCalendar.today()

    result =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "approved",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "operatorActorId" => actor_id,
        "reminderState" => "preDue"
      })

    assert result.status == "approved"
    assert result.dueOn == today |> Date.add(1) |> Date.to_iso8601()
    assert result.owedKind == "pre_due"

    revision = Date.to_gregorian_days(Date.from_iso8601!(result.dueOn))

    assert result.notificationKey ==
             "inventory:loan:#{result.loanId}:reminder:pre_due:r#{revision}"

    delivered = LoanReminders.run(today)
    assert delivered.delivered == 1

    again = LoanReminders.run(today)
    assert again.delivered == 0

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", result.loanId)
  end

  test "reminderState weekly owes the follow-up paced from delivery" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("rem-weekly-actor-#{uniq}")
    borrower_id = principal_id!("rem-weekly-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)
    today = ClubCalendar.today()

    result =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "checkedOut",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "operatorActorId" => actor_id,
        "reminderState" => "weekly"
      })

    assert result.status == "checked_out"
    assert result.owedKind == "overdue_week_1"

    revision = Date.to_gregorian_days(Date.from_iso8601!(result.dueOn))

    assert result.notificationKey ==
             "inventory:loan:#{result.loanId}:reminder:overdue_week_1:r#{revision}"

    delivered = LoanReminders.run(today)
    assert delivered.delivered == 1

    # A second run with no state change delivers nothing — no dupes across
    # retries.
    assert %{delivered: 0} = LoanReminders.run(today)

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", result.loanId)
  end

  test "reminderState on a closed loan earns nothing" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("rem-closed-actor-#{uniq}")
    borrower_id = principal_id!("rem-closed-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)

    result =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "returned",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "operatorActorId" => actor_id,
        "reminderState" => "overdue"
      })

    assert result.status == "returned"
    assert result.owedKind == nil
    assert result.notificationKey == nil

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", result.loanId)
  end

  defp seed_item!(actor_id, uniq) do
    structure =
      E2EHarness.seed("inventoryStructure", %{
        "categoryName" => "E2E Maint Cat #{uniq}",
        "definitions" => [],
        "containerPath" => ["E2E Maint Cage #{uniq}", "Rack #{uniq}"],
        "actorId" => actor_id
      })

    leaf = List.last(structure.containers)

    E2EHarness.seed("inventoryItem", %{
      "categoryId" => structure.categoryId,
      "containerId" => leaf.containerId,
      "actorId" => actor_id
    })
  end

  defp due_in(days), do: ClubCalendar.today() |> Date.add(days) |> Date.to_iso8601()

  defp principal_id!(slug) do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{email: "#{slug}@example.com"})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
