defmodule Dhc.Inventory.ExpandTest do
  @moduledoc """
  ALE-282: target inventory tables (nuke-ok, no backfill).

  Proves the target storage migration deployed cleanly (tables, restrictive
  keys, backstop constraints). Legacy inventory is unused — rows need no
  preservation, no backfill, no dual-write.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Repo

  describe "no target command is reachable" do
    test "public seam exposes no target lifecycle functions" do
      for fun <- [
            :create_loan,
            :approve_loan,
            :start_maintenance,
            :end_maintenance,
            :archive_item,
            :restore_item,
            :request_loan
          ] do
        refute function_exported?(Inventory, fun, 1),
               "expected Dhc.Inventory.#{fun}/1 to stay unexposed in expand"

        refute function_exported?(Inventory, fun, 2),
               "expected Dhc.Inventory.#{fun}/2 to stay unexposed in expand"
      end
    end
  end

  describe "additive storage" do
    test "slug column is nullable with a unique-where-present index and a sequence" do
      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*) FROM inventory_item_slug_seq", [])

      columns = table_columns("inventory_items")
      assert "slug" in columns
      assert "archived_at" in columns
      assert "archived_by_principal_id" in columns

      category = insert_category()
      container_id = insert_container!()
      {:ok, item_a} = insert_item(container_id, category.id)
      {:ok, item_b} = insert_item(container_id, category.id)

      Repo.query!("UPDATE inventory_items SET slug = 'item-000001' WHERE id = $1", [
        Ecto.UUID.dump!(item_a)
      ])

      assert_raise Postgrex.Error, ~r/duplicate key|unique/i, fn ->
        Repo.query!("UPDATE inventory_items SET slug = 'item-000001' WHERE id = $1", [
          Ecto.UUID.dump!(item_b)
        ])
      end
    end

    test "archive columns exist on categories and containers" do
      assert "archived_at" in table_columns("equipment_categories")
      assert "archived_at" in table_columns("containers")
    end

    test "typed property tables enforce uniqueness and exactly-one value" do
      category = insert_category()
      definition_id = insert_definition!(category.id, "Size")

      # Case-insensitive label uniqueness per category.
      assert_raise Postgrex.Error, ~r/duplicate key|unique/i, fn ->
        insert_definition!(category.id, "size")
      end

      option_id = insert_option!(definition_id, "Large")

      assert_raise Postgrex.Error, ~r/duplicate key|unique/i, fn ->
        insert_option!(definition_id, "LARGE")
      end

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)

      # Empty insert violates the exactly-one check.
      assert_raise Postgrex.Error, ~r/exactly_one/i, fn ->
        Repo.query!(
          "INSERT INTO inventory_item_property_values (item_id, property_definition_id, created_at, updated_at) VALUES ($1, $2, NOW(), NOW())",
          [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(definition_id)]
        )
      end

      # Two values set also violates it.
      assert_raise Postgrex.Error, ~r/exactly_one/i, fn ->
        Repo.query!(
          "INSERT INTO inventory_item_property_values (item_id, property_definition_id, text_value, boolean_value, created_at, updated_at) VALUES ($1, $2, 'x', TRUE, NOW(), NOW())",
          [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(definition_id)]
        )
      end

      # Exactly one value is fine.
      assert %Postgrex.Result{} =
               Repo.query!(
                 "INSERT INTO inventory_item_property_values (item_id, property_definition_id, option_id, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
                 [
                   Ecto.UUID.dump!(item_id),
                   Ecto.UUID.dump!(definition_id),
                   Ecto.UUID.dump!(option_id)
                 ]
               )
    end

    test "maintenance periods allow one open period per item" do
      category = insert_category()
      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      principal_id = insert_principal!()

      insert_maintenance!(item_id, principal_id, "Blade wobble")

      assert_raise Postgrex.Error, ~r/one_open_per_item/i, fn ->
        insert_maintenance!(item_id, principal_id, "Second fault")
      end
    end

    test "loans enforce status, pending-request, and single-allocation guards" do
      category = insert_category()
      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      borrower_a = insert_principal!()
      borrower_b = insert_principal!()

      insert_loan!(item_id, borrower_a, "requested")

      # One pending request per item/borrower.
      assert_raise Postgrex.Error, ~r/one_pending_request/i, fn ->
        insert_loan!(item_id, borrower_a, "requested")
      end

      # A second borrower may still request (no queue until approval).
      insert_loan!(item_id, borrower_b, "requested")

      # Unknown status fails the status check.
      assert_raise Postgrex.Error, ~r/status_check/i, fn ->
        insert_loan!(item_id, borrower_a, "lost")
      end
    end

    test "reminder ledger is keyed by loan, recipient, kind, and revision" do
      category = insert_category()
      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      borrower = insert_principal!()
      loan_id = insert_loan!(item_id, borrower, "requested")

      insert_reminder!(loan_id, borrower, "due_soon", 0)

      assert_raise Postgrex.Error, ~r/ledger_key_unique/i, fn ->
        insert_reminder!(loan_id, borrower, "due_soon", 0)
      end

      # A due-date revision is a new ledger key (no stale retry).
      insert_reminder!(loan_id, borrower, "due_soon", 1)
    end

    test "new foreign keys are restrictive" do
      category = insert_category()
      definition_id = insert_definition!(category.id, "Brand")

      # Category with a definition reference cannot be deleted.
      assert_raise Postgrex.Error, ~r/violates foreign key|restrict/i, fn ->
        Repo.query!("DELETE FROM equipment_categories WHERE id = $1", [
          Ecto.UUID.dump!(category.id)
        ])
      end

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      principal_id = insert_principal!()
      insert_maintenance!(item_id, principal_id, "Faulty guard")

      # Item with a maintenance fact cannot be deleted.
      assert_raise Postgrex.Error, ~r/violates foreign key|restrict/i, fn ->
        Repo.query!("DELETE FROM inventory_items WHERE id = $1", [Ecto.UUID.dump!(item_id)])
      end

      assert definition_id != nil
    end

    test "typed values must match definition type and option membership" do
      category = insert_category()
      text_id = insert_definition!(category.id, "Note", "text")
      select_id = insert_definition!(category.id, "Guard", "single_select")
      option_id = insert_option!(select_id, "Large")
      other_id = insert_definition!(category.id, "Other", "single_select")
      other_option = insert_option!(other_id, "Small")
      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)

      assert_raise Postgrex.Error, ~r/value_type_match|check/i, fn ->
        Repo.query!(
          "INSERT INTO inventory_item_property_values (item_id, property_definition_id, boolean_value, created_at, updated_at) VALUES ($1, $2, TRUE, NOW(), NOW())",
          [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(text_id)]
        )
      end

      assert_raise Postgrex.Error, ~r/option_membership|check|foreign key/i, fn ->
        Repo.query!(
          "INSERT INTO inventory_item_property_values (item_id, property_definition_id, option_id, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
          [
            Ecto.UUID.dump!(item_id),
            Ecto.UUID.dump!(select_id),
            Ecto.UUID.dump!(other_option)
          ]
        )
      end

      assert %Postgrex.Result{} =
               Repo.query!(
                 "INSERT INTO inventory_item_property_values (item_id, property_definition_id, option_id, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
                 [
                   Ecto.UUID.dump!(item_id),
                   Ecto.UUID.dump!(select_id),
                   Ecto.UUID.dump!(option_id)
                 ]
               )

      assert_raise Postgrex.Error, ~r/value_type_match|check/i, fn ->
        Repo.query!(
          "UPDATE inventory_property_definitions SET value_type = 'text' WHERE id = $1",
          [Ecto.UUID.dump!(select_id)]
        )
      end

      assert_raise Postgrex.Error, ~r/option_membership|check/i, fn ->
        Repo.query!(
          "UPDATE inventory_property_options SET property_definition_id = $1 WHERE id = $2",
          [Ecto.UUID.dump!(other_id), Ecto.UUID.dump!(option_id)]
        )
      end
    end

    test "new target columns default to NULL: legacy rows need no preservation" do
      category = insert_category()
      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id, quantity: 3)

      # New target columns default to NULL — legacy rows need no preservation.
      assert %{rows: [[nil, nil]]} =
               Repo.query!("SELECT slug, archived_at FROM inventory_items WHERE id = $1", [
                 Ecto.UUID.dump!(item_id)
               ])
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp table_columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  defp insert_principal! do
    user_id = Ecto.UUID.generate()

    %Principal{id: user_id}
    |> Principal.email_changeset(%{
      email: "expand-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp insert_category do
    {:ok, category} =
      Dhc.Inventory.EquipmentCategory
      |> struct()
      |> Ecto.Changeset.cast(
        %{name: "Expand Cat #{System.unique_integer([:positive])}"},
        [:name]
      )
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  defp insert_container! do
    user_id = insert_principal!()
    container_id = Ecto.UUID.generate()

    %Postgrex.Result{} =
      Repo.query!(
        "INSERT INTO containers (id, name, created_by, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
        [Ecto.UUID.dump!(container_id), "Expand Container", Ecto.UUID.dump!(user_id)]
      )

    container_id
  end

  defp insert_item(container_id, category_id, opts \\ []) do
    item_id = Ecto.UUID.generate()
    quantity = Keyword.get(opts, :quantity, 1)

    %Postgrex.Result{} =
      Repo.query!(
        "INSERT INTO inventory_items (id, container_id, category_id, attributes, quantity, created_at, updated_at) VALUES ($1, $2, $3, '{}'::jsonb, $4, NOW(), NOW())",
        [
          Ecto.UUID.dump!(item_id),
          Ecto.UUID.dump!(container_id),
          Ecto.UUID.dump!(category_id),
          quantity
        ]
      )

    {:ok, item_id}
  end

  defp insert_definition!(category_id, label, value_type \\ "single_select") do
    definition_id = Ecto.UUID.generate()

    %Postgrex.Result{} =
      Repo.query!(
        "INSERT INTO inventory_property_definitions (id, category_id, label, value_type, required, created_at, updated_at) VALUES ($1, $2, $3, $4, FALSE, NOW(), NOW())",
        [Ecto.UUID.dump!(definition_id), Ecto.UUID.dump!(category_id), label, value_type]
      )

    definition_id
  end

  defp insert_option!(definition_id, label) do
    option_id = Ecto.UUID.generate()

    %Postgrex.Result{} =
      Repo.query!(
        "INSERT INTO inventory_property_options (id, property_definition_id, label, position, created_at, updated_at) VALUES ($1, $2, $3, 0, NOW(), NOW())",
        [Ecto.UUID.dump!(option_id), Ecto.UUID.dump!(definition_id), label]
      )

    option_id
  end

  defp insert_maintenance!(item_id, principal_id, reason) do
    maintenance_id = Ecto.UUID.generate()

    %Postgrex.Result{} =
      Repo.query!(
        "INSERT INTO inventory_maintenance_periods (id, item_id, started_at, started_by_principal_id, start_reason, created_at, updated_at) VALUES ($1, $2, NOW(), $3, $4, NOW(), NOW())",
        [
          Ecto.UUID.dump!(maintenance_id),
          Ecto.UUID.dump!(item_id),
          Ecto.UUID.dump!(principal_id),
          reason
        ]
      )

    maintenance_id
  end

  defp insert_loan!(item_id, borrower_id, status) do
    loan_id = Ecto.UUID.generate()

    %Postgrex.Result{} =
      Repo.query!(
        """
        INSERT INTO inventory_loans
          (id, item_id, borrower_principal_id, status, requested_start_on, requested_due_on,
           item_slug_snapshot, item_label_snapshot, created_at, updated_at)
        VALUES ($1, $2, $3, $4, CURRENT_DATE, CURRENT_DATE + 7, 'item-000001', 'Label', NOW(), NOW())
        """,
        [Ecto.UUID.dump!(loan_id), Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(borrower_id), status]
      )

    loan_id
  end

  defp insert_reminder!(loan_id, recipient_id, kind, revision) do
    reminder_id = Ecto.UUID.generate()

    %Postgrex.Result{} =
      Repo.query!(
        "INSERT INTO inventory_loan_reminders (id, loan_id, recipient_principal_id, kind, due_on_revision, scheduled_for, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, NOW() + INTERVAL '1 day', NOW(), NOW())",
        [
          Ecto.UUID.dump!(reminder_id),
          Ecto.UUID.dump!(loan_id),
          Ecto.UUID.dump!(recipient_id),
          kind,
          revision
        ]
      )

    reminder_id
  end
end
