defmodule Dhc.Inventory.OperatorItemLifecycleTest do
  @moduledoc """
  ALE-294 (ALE-284b): item movement, maintenance periods, and archive
  interlocks.

  Proves through `Dhc.Inventory` that movement is a dedicated command
  respecting loan and maintenance state, that maintenance is a retained
  period with at most one open per item, that archive replaces destructive
  deletion once history exists, that restore is gated on active
  dependencies and still-valid required values, and that availability is
  only ever a projection.

  Loan rows are inserted directly: the loan commands themselves are
  ALE-286. Direct SQL otherwise appears only for the backstops the seam
  cannot express (the partial unique index on open periods) and to prove
  target paths never write `inventory_history` or the legacy
  `out_for_maintenance` flag.

  Since GH-508 the availability-changing commands here are a facade over
  `Dhc.Inventory.AvailabilityCommands`, so this file keeps only the item
  contract — signatures, return shapes, and the item-specific rules such as
  delete and restore gating. Concurrency, lock order, and the partial-index
  backstops are proven once in `Dhc.Inventory.AvailabilityCommandsTest`.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Repo

  describe "movement" do
    test "moves an item to another active container" do
      %{category: category, container_id: container_id} = fixture()
      destination = create_container!()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, moved} =
               Inventory.move_operator_item(
                 item.slug,
                 %{"container_id" => destination.id},
                 principal_id()
               )

      assert moved.container_id == destination.id
      assert moved.container["id"] == destination.id

      assert {:ok, resolved} = Inventory.resolve_operator_item(item.id)
      assert resolved.container_id == destination.id
    end

    test "is allowed while the item is in maintenance" do
      %{category: category, container_id: container_id} = fixture()
      destination = create_container!()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(
          item.id,
          %{"reason" => "Rebate needed"},
          principal_id()
        )

      assert {:ok, moved} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => destination.id},
                 principal_id()
               )

      assert moved.container_id == destination.id
      # Moving does not end the period.
      assert [%{ended_at: nil}] = Inventory.list_operator_item_maintenance_periods(item.id)
    end

    test "is blocked while a loan is approved or checked out" do
      %{category: category, container_id: container_id} = fixture()
      destination = create_container!()
      {:ok, item} = create_item(container_id, category.id)

      loan_id = create_loan!(item, principal_id(), "approved")

      assert {:error, :loan_active} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => destination.id},
                 principal_id()
               )

      set_loan_status!(loan_id, "checked_out")

      assert {:error, :loan_active} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => destination.id},
                 principal_id()
               )

      assert {:ok, %{container_id: unchanged}} = Inventory.resolve_operator_item(item.id)
      assert unchanged == container_id
    end

    test "is allowed once the loan is returned, rejected, or cancelled" do
      %{category: category, container_id: container_id} = fixture()
      destination = create_container!()
      {:ok, item} = create_item(container_id, category.id)

      loan_id = create_loan!(item, principal_id(), "checked_out")
      set_loan_status!(loan_id, "returned")

      assert {:ok, moved} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => destination.id},
                 principal_id()
               )

      assert moved.container_id == destination.id
    end

    test "a pending request does not block movement" do
      %{category: category, container_id: container_id} = fixture()
      destination = create_container!()
      {:ok, item} = create_item(container_id, category.id)

      loan_id = create_loan!(item, principal_id(), "requested")

      assert {:ok, _moved} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => destination.id},
                 principal_id()
               )

      # Movement is not an allocation decision: the request survives.
      assert loan_status(loan_id) == "requested"
    end

    test "rejects an unknown or archived destination container" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:error, :not_found} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => Ecto.UUID.generate()},
                 principal_id()
               )

      assert {:error, :not_found} =
               Inventory.move_operator_item(item.id, %{}, principal_id())

      archived = create_container!()
      {:ok, _} = Inventory.archive_container(archived.id)

      assert {:error, :archived_container} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => archived.id},
                 principal_id()
               )
    end

    test "rejects moving an archived item" do
      %{category: category, container_id: container_id} = fixture()
      destination = create_container!()
      {:ok, item} = create_item(container_id, category.id)
      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      assert {:error, :archived} =
               Inventory.move_operator_item(
                 item.id,
                 %{"container_id" => destination.id},
                 principal_id()
               )
    end

    test "is never a general edit: notes, values, and category are ignored" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      destination = create_container!()
      other_category = create_category!()

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "notes" => "keep me",
            "values" => %{brand.id => "Regenyei"}
          },
          principal_id()
        )

      assert {:ok, moved} =
               Inventory.move_operator_item(
                 item.id,
                 %{
                   "container_id" => destination.id,
                   "notes" => "overwritten?",
                   "category_id" => other_category.id,
                   "values" => %{}
                 },
                 principal_id()
               )

      assert moved.container_id == destination.id
      assert moved.notes == "keep me"
      assert moved.category_id == category.id
      assert [%{text: "Regenyei"}] = moved.values
    end
  end

  describe "starting maintenance" do
    test "starts immediately with a required reason and recorded principal" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      operator = principal_id()

      assert {:ok, started} =
               Inventory.start_operator_item_maintenance(
                 item.id,
                 %{"reason" => "Blade chipped"},
                 operator
               )

      assert started.availability == %{available?: false, status: :maintenance}

      assert [period] = Inventory.list_operator_item_maintenance_periods(item.id)
      assert period.start_reason == "Blade chipped"
      assert period.started_by_principal_id == operator
      assert period.open?
      assert period.ended_at == nil
      assert %DateTime{} = period.started_at
    end

    test "requires a reason" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      for attrs <- [%{}, %{"reason" => nil}, %{"reason" => "   "}, %{"reason" => 42}] do
        assert {:error, :reason_required} =
                 Inventory.start_operator_item_maintenance(item.id, attrs, principal_id())
      end

      assert Inventory.list_operator_item_maintenance_periods(item.id) == []
    end

    test "allows at most one open period per item" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "first"}, principal_id())

      assert {:error, :maintenance_open} =
               Inventory.start_operator_item_maintenance(
                 item.id,
                 %{"reason" => "second"},
                 principal_id()
               )

      assert [%{start_reason: "first"}] =
               Inventory.list_operator_item_maintenance_periods(item.id)
    end

    test "atomically rejects pending requests" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      first = create_loan!(item, principal_id(), "requested")
      second = create_loan!(item, principal_id(), "requested")
      operator = principal_id()

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.id,
                 %{"reason" => "Servicing"},
                 operator
               )

      for loan_id <- [first, second] do
        assert loan_status(loan_id) == "rejected"

        assert %{decided_by: ^operator, decision_note: note, decided_at: %DateTime{}} =
                 loan_decision(loan_id)

        assert note =~ "maintenance"
      end
    end

    test "is blocked by an approved or checked-out loan and writes nothing" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      pending = create_loan!(item, principal_id(), "requested")
      loan_id = create_loan!(item, principal_id(), "approved")

      assert {:error, :loan_active} =
               Inventory.start_operator_item_maintenance(
                 item.id,
                 %{"reason" => "Servicing"},
                 principal_id()
               )

      set_loan_status!(loan_id, "checked_out")

      assert {:error, :loan_active} =
               Inventory.start_operator_item_maintenance(
                 item.id,
                 %{"reason" => "Servicing"},
                 principal_id()
               )

      # The failed command neither opened a period nor rejected the request.
      assert Inventory.list_operator_item_maintenance_periods(item.id) == []
      assert loan_status(pending) == "requested"
    end

    test "rejects starting maintenance on an archived item" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      assert {:error, :archived} =
               Inventory.start_operator_item_maintenance(
                 item.id,
                 %{"reason" => "nope"},
                 principal_id()
               )
    end

    test "rejects an unknown item" do
      assert {:error, :not_found} =
               Inventory.start_operator_item_maintenance(
                 "item-999999",
                 %{"reason" => "nope"},
                 principal_id()
               )
    end
  end

  describe "ending maintenance" do
    test "ends with an optional note, retaining both timestamps and principals" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      opener = principal_id()
      closer = principal_id()

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "Rebate"}, opener)

      assert {:ok, ended} =
               Inventory.end_operator_item_maintenance(
                 item.id,
                 %{"end_note" => "Reground and oiled"},
                 closer
               )

      assert ended.availability == %{available?: true, status: :available}

      assert [period] = Inventory.list_operator_item_maintenance_periods(item.id)
      assert period.start_reason == "Rebate"
      assert period.started_by_principal_id == opener
      assert period.end_note == "Reground and oiled"
      assert period.ended_by_principal_id == closer
      refute period.open?
      assert DateTime.compare(period.ended_at, period.started_at) in [:gt, :eq]
    end

    test "the end note is optional" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(
          item.id,
          %{"reason" => "Rebate"},
          principal_id()
        )

      assert {:ok, _} = Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())
      assert [%{end_note: nil, open?: false}] = maintenance_periods(item.id)
    end

    test "errors when no period is open" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:error, :no_open_maintenance} =
               Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())

      {:ok, _} =
        Inventory.start_operator_item_maintenance(
          item.id,
          %{"reason" => "Rebate"},
          principal_id()
        )

      {:ok, _} = Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())

      assert {:error, :no_open_maintenance} =
               Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())
    end

    test "refuses to end maintenance on an archived item" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "Bent"}, principal_id())

      # Archiving already closed the period atomically, so there is nothing
      # left to end and an archived item stays read-only.
      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      assert {:error, :archived} =
               Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())
    end

    test "an item can re-enter maintenance as a new retained period" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "first"}, principal_id())

      {:ok, _} = Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())

      {:ok, _} =
        Inventory.start_operator_item_maintenance(
          item.id,
          %{"reason" => "second"},
          principal_id()
        )

      assert [%{start_reason: "second", open?: true}, %{start_reason: "first", open?: false}] =
               Inventory.list_operator_item_maintenance_periods(item.id)
    end
  end

  describe "archive" do
    test "archives an item that has loan history instead of deleting it" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      loan_id = create_loan!(item, principal_id(), "checked_out")
      set_loan_status!(loan_id, "returned")
      operator = principal_id()

      assert {:ok, archived} = Inventory.archive_operator_item(item.id, %{}, operator)

      assert %DateTime{} = archived.archived_at
      assert archived.archived_by_principal_id == operator
      assert archived.availability == %{available?: false, status: :archived}

      # The row and its loan history survive.
      assert {:ok, %{archived_at: %DateTime{}}} = Inventory.resolve_operator_item(item.slug)
      assert loan_status(loan_id) == "returned"
    end

    test "rejects pending requests" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      pending = create_loan!(item, principal_id(), "requested")
      operator = principal_id()

      assert {:ok, _} = Inventory.archive_operator_item(item.id, %{}, operator)

      assert loan_status(pending) == "rejected"
      assert %{decided_by: ^operator, decision_note: note} = loan_decision(pending)
      assert note =~ "archiv"
    end

    test "is blocked by an approved or checked-out loan and writes nothing" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      pending = create_loan!(item, principal_id(), "requested")
      loan_id = create_loan!(item, principal_id(), "approved")

      assert {:error, :loan_active} =
               Inventory.archive_operator_item(item.id, %{}, principal_id())

      set_loan_status!(loan_id, "checked_out")

      assert {:error, :loan_active} =
               Inventory.archive_operator_item(item.id, %{}, principal_id())

      assert {:ok, %{archived_at: nil}} = Inventory.resolve_operator_item(item.id)
      assert loan_status(pending) == "requested"
    end

    test "atomically ends an open maintenance period with an archive reason" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(
          item.id,
          %{"reason" => "Cracked guard"},
          principal_id()
        )

      operator = principal_id()

      assert {:ok, _} =
               Inventory.archive_operator_item(item.id, %{"reason" => "Retired at v4"}, operator)

      assert [period] = Inventory.list_operator_item_maintenance_periods(item.id)
      refute period.open?
      assert period.ended_by_principal_id == operator
      assert period.end_note =~ "Retired at v4"
    end

    test "ends an open period even when no archive reason is supplied" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "Bent"}, principal_id())

      assert {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      assert [%{open?: false, end_note: end_note}] =
               Inventory.list_operator_item_maintenance_periods(item.id)

      assert end_note =~ "archiv"
    end

    test "archiving an already archived item is idempotent" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, first} = Inventory.archive_operator_item(item.id, %{}, principal_id())
      assert {:ok, second} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      assert second.archived_at == first.archived_at
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
      loan_id = create_loan!(item, principal_id(), "checked_out")
      set_loan_status!(loan_id, "returned")

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
    test "restores an archived item when every dependency is active" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      assert {:ok, restored} = Inventory.restore_operator_item(item.id, principal_id())

      assert restored.archived_at == nil
      assert restored.archived_by_principal_id == nil
      assert restored.availability == %{available?: true, status: :available}
    end

    test "is blocked while the category is archived" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())
      archive_category!(category.id)

      assert {:error, :archived_category} =
               Inventory.restore_operator_item(item.id, principal_id())

      assert {:ok, %{archived_at: %DateTime{}}} = Inventory.resolve_operator_item(item.id)
    end

    test "is blocked while the container chain is archived" do
      %{category: category} = fixture()
      parent = create_container!()

      {:ok, child} =
        Inventory.create_container(
          %{
            "name" => "Shelf #{System.unique_integer([:positive])}",
            "parent_container_id" => parent.id
          },
          principal_id()
        )

      {:ok, item} = create_item(child.id, category.id)
      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())

      # Archiving the item frees the chain to archive from the leaf upward.
      {:ok, _} = Inventory.archive_container(child.id)
      {:ok, _} = Inventory.archive_container(parent.id)

      assert {:error, :archived_container} =
               Inventory.restore_operator_item(item.id, principal_id())
    end

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
      Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [
        Ecto.UUID.dump!(item.id)
      ])

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

    test "restoring an active item is idempotent" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, restored} = Inventory.restore_operator_item(item.id, principal_id())
      assert restored.archived_at == nil
    end
  end

  describe "availability is a projection" do
    test "reflects open maintenance, then active loans, then availability again" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, %{availability: %{available?: true, status: :available}}} =
               Inventory.resolve_operator_item(item.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "Bent"}, principal_id())

      assert {:ok, %{availability: %{available?: false, status: :maintenance}}} =
               Inventory.resolve_operator_item(item.id)

      {:ok, _} = Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())

      assert {:ok, %{availability: %{available?: true, status: :available}}} =
               Inventory.resolve_operator_item(item.id)

      loan_id = create_loan!(item, principal_id(), "approved")

      assert {:ok, %{availability: %{available?: false, status: :on_loan}}} =
               Inventory.resolve_operator_item(item.id)

      set_loan_status!(loan_id, "checked_out")

      assert {:ok, %{availability: %{available?: false, status: :on_loan}}} =
               Inventory.resolve_operator_item(item.id)

      set_loan_status!(loan_id, "returned")

      assert {:ok, %{availability: %{available?: true, status: :available}}} =
               Inventory.resolve_operator_item(item.id)
    end

    test "a pending request never makes an item unavailable" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      _pending = create_loan!(item, principal_id(), "requested")

      assert {:ok, %{availability: %{available?: true}}} =
               Inventory.resolve_operator_item(item.id)
    end

    test "no column stores availability and no legacy columns remain" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "Bent"}, principal_id())

      columns = item_columns()
      refute "availability" in columns
      refute "available" in columns

      # ALE-289 dropped the legacy boolean and its siblings outright.
      for legacy <- ~w(quantity photo_url attributes out_for_maintenance) do
        refute legacy in columns
      end
    end
  end

  # Real races commit outside the test-owner transaction, so each of these
  # runs `unboxed_run` and cleans up its own committed rows
  # (docs/agents/critical-patterns.md, "Real PostgreSQL Concurrency Tests").
  describe "database backstops" do
    test "target lifecycle paths have no history table to write" do
      %{category: category, container_id: container_id} = fixture()
      destination = create_container!()
      {:ok, item} = create_item(container_id, category.id)

      {:ok, _} =
        Inventory.move_operator_item(
          item.id,
          %{"container_id" => destination.id},
          principal_id()
        )

      {:ok, _} =
        Inventory.start_operator_item_maintenance(item.id, %{"reason" => "Bent"}, principal_id())

      {:ok, _} = Inventory.end_operator_item_maintenance(item.id, %{}, principal_id())
      {:ok, _} = Inventory.archive_operator_item(item.id, %{}, principal_id())
      {:ok, _} = Inventory.restore_operator_item(item.id, principal_id())

      # ALE-289 dropped the generic-history table: movement, maintenance,
      # and archive leave retained facts in their own tables, not rows here.
      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'inventory_history')",
                 []
               )
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

  # Loan rows are fixtures here: the lifecycle commands are ALE-286.
  defp create_loan!(item, borrower_id, status) do
    %{rows: [[loan_id]]} =
      Repo.query!(
        """
        INSERT INTO inventory_loans (
          item_id, borrower_principal_id, status,
          requested_start_on, requested_due_on,
          item_slug_snapshot, item_label_snapshot,
          created_at, updated_at
        )
        VALUES ($1, $2, $3, CURRENT_DATE, CURRENT_DATE + 7, $4, $5, NOW(), NOW())
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(item.id),
          Ecto.UUID.dump!(borrower_id),
          status,
          item.slug,
          item.label || item.slug
        ]
      )

    Ecto.UUID.load!(loan_id)
  end

  defp set_loan_status!(loan_id, status) do
    Repo.query!("UPDATE inventory_loans SET status = $1 WHERE id = $2", [
      status,
      Ecto.UUID.dump!(loan_id)
    ])
  end

  defp loan_status(loan_id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM inventory_loans WHERE id = $1", [
        Ecto.UUID.dump!(loan_id)
      ])

    status
  end

  defp loan_decision(loan_id) do
    %{rows: [[decided_at, decided_by, decision_note]]} =
      Repo.query!(
        "SELECT decided_at, decided_by_principal_id, decision_note FROM inventory_loans WHERE id = $1",
        [Ecto.UUID.dump!(loan_id)]
      )

    %{
      decided_at: decided_at,
      decided_by: decided_by && Ecto.UUID.load!(decided_by),
      decision_note: decision_note
    }
  end

  defp maintenance_periods(item_id), do: Inventory.list_operator_item_maintenance_periods(item_id)

  defp archive_category!(category_id) do
    Repo.query!("UPDATE equipment_categories SET archived_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(category_id)
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

  defp item_columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'inventory_items'",
        []
      )

    List.flatten(rows)
  end
end
