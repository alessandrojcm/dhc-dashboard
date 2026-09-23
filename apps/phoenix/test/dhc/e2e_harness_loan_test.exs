defmodule Dhc.E2EHarnessLoanTest do
  @moduledoc """
  ALE-288 IMPL-03: round-trip for the frozen `inventoryLoan` scenario.

  Seeds through `Dhc.E2EHarness` on top of `inventoryStructure` +
  `inventoryItem` (ids, never names): requested with no entitlement,
  approved with the container-path snapshot, the full lifecycle presets,
  overdue as derived state, and the competing pair whose live approval
  allocates exactly once. Every seed deletes per contract (test-only
  hard-delete, never cascading).
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.E2EHarness
  alias Dhc.Inventory
  alias Dhc.ClubCalendar
  alias Dhc.Repo

  test "requested seeds with no container path and deletes" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("loan-req-actor-#{uniq}")
    borrower_id = principal_id!("loan-req-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)

    result =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "requested",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "note" => "Need a feder for Thursday sparring"
      })

    assert Enum.sort(Map.keys(result)) == [
             :borrowerMemberId,
             :containerPath,
             :decidedBy,
             :dueOn,
             :itemId,
             :loanId,
             :notificationKey,
             :overdue,
             :owedKind,
             :slug,
             :startsOn,
             :status
           ]

    assert result.status == "requested"
    assert result.overdue == false
    assert result.itemId == item.itemId
    assert result.slug == item.slug
    assert result.borrowerMemberId == borrower_id
    assert result.containerPath == nil
    assert result.decidedBy == nil
    assert result.owedKind == nil
    assert result.notificationKey == nil

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", result.loanId)
    assert Repo.get(Dhc.Inventory.Loan, result.loanId) == nil
  end

  test "approved exposes the container path while requested does not" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("loan-appr-actor-#{uniq}")
    borrower_id = principal_id!("loan-appr-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)

    requested =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "requested",
        "itemId" => item.itemId,
        "borrowerMemberId" => principal_id!("loan-appr-other-#{uniq}")
      })

    assert requested.containerPath == nil
    assert :ok = E2EHarness.delete_fixture("inventoryLoan", requested.loanId)

    approved =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "approved",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "operatorActorId" => actor_id
      })

    assert approved.status == "approved"
    assert approved.overdue == false
    assert approved.containerPath != nil
    assert approved.containerPath =~ "›"
    assert approved.decidedBy == actor_id

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", approved.loanId)
  end

  test "lifecycle presets seed to the contracted states" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("loan-life-actor-#{uniq}")

    for preset <- ~w(checkedOut returned rejected overdue) do
      borrower_id = principal_id!("loan-life-#{preset}-#{uniq}")
      item = seed_item!(actor_id, uniq + System.unique_integer([:positive]))

      result =
        E2EHarness.seed("inventoryLoan", %{
          "preset" => preset,
          "itemId" => item.itemId,
          "borrowerMemberId" => borrower_id,
          "operatorActorId" => actor_id
        })

      case preset do
        "checkedOut" ->
          assert result.status == "checked_out"
          assert result.overdue == false
          assert result.containerPath != nil
          assert result.decidedBy == actor_id

        "returned" ->
          assert result.status == "returned"
          assert result.overdue == false
          assert result.containerPath != nil

        "rejected" ->
          assert result.status == "rejected"
          assert result.overdue == false
          assert result.containerPath == nil
          assert result.decidedBy == actor_id

        "overdue" ->
          assert result.status == "checked_out"
          assert result.overdue == true
          assert result.containerPath != nil
      end

      assert :ok = E2EHarness.delete_fixture("inventoryLoan", result.loanId)
    end
  end

  test "cancelled by member and by operator" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("loan-cancel-actor-#{uniq}")

    member_item = seed_item!(actor_id, uniq + System.unique_integer([:positive]))

    member_cancelled =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "cancelled",
        "itemId" => member_item.itemId,
        "borrowerMemberId" => principal_id!("loan-cancel-member-#{uniq}"),
        "cancelledBy" => "member"
      })

    assert member_cancelled.status == "cancelled"
    assert member_cancelled.overdue == false
    assert member_cancelled.containerPath == nil
    assert member_cancelled.decidedBy == member_cancelled.borrowerMemberId
    assert :ok = E2EHarness.delete_fixture("inventoryLoan", member_cancelled.loanId)

    operator_borrower = principal_id!("loan-cancel-op-borrower-#{uniq}")
    operator_item = seed_item!(actor_id, uniq + System.unique_integer([:positive]))

    operator_cancelled =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "cancelled",
        "itemId" => operator_item.itemId,
        "borrowerMemberId" => operator_borrower,
        "operatorActorId" => actor_id,
        "cancelledBy" => "operator"
      })

    assert operator_cancelled.status == "cancelled"
    assert operator_cancelled.decidedBy == actor_id
    assert :ok = E2EHarness.delete_fixture("inventoryLoan", operator_cancelled.loanId)
  end

  test "competingPair leaves both pending and a live approval allocates once" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("loan-pair-actor-#{uniq}")
    first_borrower = principal_id!("loan-pair-first-#{uniq}")
    second_borrower = principal_id!("loan-pair-second-#{uniq}")
    item = seed_item!(actor_id, uniq)

    pair =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "competingPair",
        "itemId" => item.itemId,
        "borrowerMemberIds" => [first_borrower, second_borrower]
      })

    assert %{loans: [first, second], itemId: item_id} = pair
    assert item_id == item.itemId
    refute Map.has_key?(pair, :loanId)
    refute Map.has_key?(pair, :borrowerMemberId)

    assert first.status == "requested"
    assert second.status == "requested"
    assert first.containerPath == nil
    assert second.containerPath == nil
    assert first.borrowerMemberId == first_borrower
    assert second.borrowerMemberId == second_borrower
    assert first.loanId != second.loanId
    assert first.itemId == second.itemId

    assert {:ok, winner} = Inventory.approve_loan(first.loanId, %{}, actor_id)
    assert winner.status == "approved"

    assert {:ok, loser} = Inventory.get_operator_loan(second.loanId)
    assert loser.status == "rejected"

    assert loser.decision_note ==
             "Rejected automatically: another request for this item was approved."

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", first.loanId)
    assert :ok = E2EHarness.delete_fixture("inventoryLoan", second.loanId)
  end

  test "reminderState overdue pins geometry and owedKind" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("loan-rem-actor-#{uniq}")
    borrower_id = principal_id!("loan-rem-borrower-#{uniq}")
    item = seed_item!(actor_id, uniq)
    today = ClubCalendar.today()

    result =
      E2EHarness.seed("inventoryLoan", %{
        "preset" => "checkedOut",
        "itemId" => item.itemId,
        "borrowerMemberId" => borrower_id,
        "operatorActorId" => actor_id,
        "reminderState" => "overdue"
      })

    assert result.status == "checked_out"
    assert result.overdue == true
    assert result.dueOn == today |> Date.add(-3) |> Date.to_iso8601()
    assert result.owedKind == "overdue"

    revision = Date.to_gregorian_days(Date.from_iso8601!(result.dueOn))

    assert result.notificationKey ==
             "inventory:loan:#{result.loanId}:reminder:overdue:r#{revision}"

    assert :ok = E2EHarness.delete_fixture("inventoryLoan", result.loanId)
  end

  defp seed_item!(actor_id, uniq) do
    structure =
      E2EHarness.seed("inventoryStructure", %{
        "categoryName" => "E2E Loan Cat #{uniq}",
        "definitions" => [],
        "containerPath" => ["E2E Loan Cage #{uniq}", "Rack #{uniq}"],
        "actorId" => actor_id
      })

    leaf = List.last(structure.containers)

    E2EHarness.seed("inventoryItem", %{
      "categoryId" => structure.categoryId,
      "containerId" => leaf.containerId,
      "actorId" => actor_id
    })
  end

  defp principal_id!(slug) do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{email: "#{slug}@example.com"})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
