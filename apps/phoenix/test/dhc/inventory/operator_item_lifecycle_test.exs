defmodule Dhc.Inventory.OperatorItemLifecycleTest do
  @moduledoc """
  ALE-294 (ALE-284b): the operator item lifecycle facade.

  Since GH-508 move, maintenance, archive, and restore are a facade over
  `Dhc.Inventory.AvailabilityCommands`, whose rules, concurrency, lock order,
  and partial-index backstops are proven once in
  `Dhc.Inventory.AvailabilityCommandsTest`. This file keeps what the module
  itself owns: the maintenance-period read, delete, and the restore
  value-gate result translation (`{:error, :invalid_values, errors}`).

  Loan fixtures go through `Dhc.Inventory.request_loan/3` and the operator
  transitions. Direct SQL appears only to strip a value from an archived
  item, which no public command can express.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.ClubCalendar
  alias Dhc.Repo

  describe "maintenance period read" do
    test "lists retained periods newest first with both principals and timestamps" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      opener = principal_id()
      closer = principal_id()

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "first"}, opener)

      {:ok, _} =
        Inventory.end_operator_item_maintenance(item.id, %{"end_note" => "Oiled"}, closer)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "second"}, opener)

      assert [%{start_reason: "second", open?: true, ended_at: nil}, first] =
               Inventory.list_operator_item_maintenance_periods(item.slug)

      assert %{
               start_reason: "first",
               started_by_principal_id: ^opener,
               ended_by_principal_id: ^closer,
               end_note: "Oiled",
               open?: false
             } = first

      assert DateTime.compare(first.ended_at, first.started_at) in [:gt, :eq]
      assert Inventory.list_operator_item_maintenance_periods("item-999999") == []
    end
  end

  describe "delete" do
    test "a history-free item deletes with confirmation, taking its values" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "values" => %{brand.id => "Regenyei"}
          },
          principal_id()
        )

      assert {:ok, deleted} = Inventory.delete_operator_item(item.id, %{"confirm" => true})
      assert deleted.id == item.id
      assert deleted.label == "#{category.name} · #{item.slug}"
      assert [%{text: "Regenyei"}] = deleted.values

      assert {:error, :not_found} = Inventory.resolve_operator_item(item.id)
      assert value_row_count(item.id) == 0
    end

    test "refuses without explicit confirmation" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      for attrs <- [%{}, %{"confirm" => false}, %{"confirm" => "yes"}] do
        assert {:error, :confirmation_required} =
                 Inventory.delete_operator_item(item.id, attrs)
      end

      assert {:ok, _} = Inventory.resolve_operator_item(item.id)
    end

    test "refuses an item with loan history" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      _loan_id = loan_in_state!(item, principal_id(), "returned")

      assert {:error, :has_history} =
               Inventory.delete_operator_item(item.id, %{"confirm" => true})

      assert {:ok, _} = Inventory.resolve_operator_item(item.id)
    end

    test "refuses an item with maintenance history" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "Bent"}, principal_id())

      {:ok, _} = Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())

      assert {:error, :has_history} =
               Inventory.delete_operator_item(item.id, %{"confirm" => true})

      assert {:ok, _} = Inventory.resolve_operator_item(item.id)
    end

    test "rejects an unknown item" do
      assert {:error, :not_found} =
               Inventory.delete_operator_item("item-999999", %{"confirm" => true})
    end
  end

  describe "restore" do
    test "is blocked when a required value no longer validates" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "values" => %{brand.id => "Regenyei"}
          },
          principal_id()
        )

      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      # Strip the value while archived, then make the definition required:
      # story 19's gate only considers active items, so the archived one can
      # fall out of validity.
      strip_archived_item_values!(item.id)

      {:ok, _} = Inventory.update_definition(brand.id, %{"required" => true})

      assert {:error, :invalid_values, errors} =
               Inventory.restore_operator_item(item.id, principal_id())

      assert errors[brand.id] == :required
      assert {:ok, %{archived_at: %DateTime{}}} = Inventory.resolve_operator_item(item.id)
    end

    test "is blocked when a stored value points at a since-retired definition" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "values" => %{brand.id => "Regenyei"}
          },
          principal_id()
        )

      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())
      # Only an archived item references it, so retirement is allowed (story 21).
      {:ok, _} = Inventory.retire_definition(brand.id)

      assert {:error, :invalid_values, errors} =
               Inventory.restore_operator_item(item.id, principal_id())

      assert errors[brand.id] == :retired_definition
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp fixture do
    %{category: create_category!(), container_id: create_container!().id}
  end

  defp create_item(container_id, category_id) do
    Inventory.create_operator_item(
      %{"container_id" => container_id, "category_id" => category_id},
      principal_id()
    )
  end

  defp create_definition(category_id, label, value_type) do
    Inventory.create_definition(category_id, %{"label" => label, "value_type" => value_type})
  end

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Lifecycle category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Lifecycle container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "item-lifecycle-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp loan_in_state!(item, borrower_id, state) do
    today = ClubCalendar.today()

    {:ok, loan} =
      Inventory.request_loan(
        item.slug,
        %{"startsOn" => Date.to_iso8601(today), "dueOn" => Date.to_iso8601(Date.add(today, 7))},
        borrower_id
      )

    loan_id = loan.id

    if state in ~w(approved checked_out returned), do: approve_loan!(loan_id)
    if state in ~w(checked_out returned), do: check_out_loan!(loan_id)
    if state == "returned", do: return_loan!(loan_id)

    loan_id
  end

  defp approve_loan!(loan_id) do
    {:ok, _} = Inventory.approve_loan(loan_id, %{}, principal_id())
    loan_id
  end

  defp check_out_loan!(loan_id) do
    {:ok, _} = Inventory.check_out_loan(loan_id, %{}, principal_id())
    loan_id
  end

  defp return_loan!(loan_id) do
    {:ok, _} = Inventory.return_loan(loan_id, principal_id())
    loan_id
  end

  # Edit refuses an archived item, so no public command can strip a value
  # after archive — which is exactly the invalid state restore must reject.
  defp strip_archived_item_values!(item_id) do
    Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [
      Ecto.UUID.dump!(item_id)
    ])
  end

  defp value_row_count(item_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM inventory_item_property_values WHERE item_id = $1",
        [Ecto.UUID.dump!(item_id)]
      )

    count
  end
end
