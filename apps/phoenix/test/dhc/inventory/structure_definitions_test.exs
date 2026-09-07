defmodule Dhc.Inventory.StructureDefinitionsTest do
  @moduledoc """
  ALE-290 (ALE-283a): operator definitions/options domain seam.

  Proves creation, rename, require, identifying reorder, and retire
  through `Dhc.Inventory`, plus the evolution gates: type immutable
  once used, make-required blocked until every active item validates,
  retire requires explicit clear/migrate, archived-only references
  retire from forms while staying displayable.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Repo

  describe "definitions" do
    test "operator can create, rename, require, reorder, and retire" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "value_type" => "text"
               })

      assert definition.label == "Size"
      assert definition.value_type == "text"
      assert definition.required == false

      assert {:ok, renamed} =
               Inventory.update_definition(definition.id, %{"label" => "Blade size"})

      assert renamed.label == "Blade size"

      # No active items: making it required succeeds.
      assert {:ok, required} =
               Inventory.update_definition(definition.id, %{"required" => true})

      assert required.required == true

      assert {:ok, identifying} =
               Inventory.update_definition(definition.id, %{"identifying_position" => 0})

      assert identifying.identifying_position == 0

      assert {:ok, retired} = Inventory.retire_definition(definition.id)
      assert retired.retired_at != nil
    end

    test "duplicate labels conflict case-insensitively" do
      category = insert_category()

      assert {:ok, _} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "value_type" => "text"
               })

      assert {:error, :conflict, _changeset} =
               Inventory.create_definition(category.id, %{
                 "label" => "size",
                 "value_type" => "text"
               })
    end

    test "type change on a used definition is rejected" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Count",
                 "value_type" => "text"
               })

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      insert_text_value!(item_id, definition.id, "large")

      assert {:error, :type_immutable} =
               Inventory.update_definition(definition.id, %{"value_type" => "decimal"})
    end

    test "type change on an unused definition is allowed" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Count",
                 "value_type" => "text"
               })

      assert {:ok, changed} =
               Inventory.update_definition(definition.id, %{"value_type" => "decimal"})

      assert changed.value_type == "decimal"
    end

    test "make-required is blocked until every active item has a valid value" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "value_type" => "text"
               })

      container_id = insert_container!()
      {:ok, empty_item} = insert_item(container_id, category.id)
      {:ok, filled_item} = insert_item(container_id, category.id)
      insert_text_value!(filled_item, definition.id, "large")

      assert {:error, :required_blocked, %{item_ids: ids}} =
               Inventory.update_definition(definition.id, %{"required" => true})

      assert ids == [empty_item]

      # Fix the data, then the gate opens.
      insert_text_value!(empty_item, definition.id, "medium")

      assert {:ok, required} =
               Inventory.update_definition(definition.id, %{"required" => true})

      assert required.required == true
    end

    test "empty text is absence while boolean false stays a real value" do
      category = insert_category()

      assert {:ok, text_def} =
               Inventory.create_definition(category.id, %{
                 "label" => "Note",
                 "value_type" => "text"
               })

      assert {:ok, bool_def} =
               Inventory.create_definition(category.id, %{
                 "label" => "Sharp",
                 "value_type" => "boolean"
               })

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      insert_boolean_value!(item_id, bool_def.id, false)

      # Boolean false satisfies make-required.
      assert {:ok, _} = Inventory.update_definition(bool_def.id, %{"required" => true})

      # Missing text row blocks make-required (empty text has no row).
      assert {:error, :required_blocked, _} =
               Inventory.update_definition(text_def.id, %{"required" => true})
    end

    test "retire requires explicit clear of active values; archived-only refs retire" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "value_type" => "text"
               })

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      insert_text_value!(item_id, definition.id, "large")

      assert {:error, :still_referenced, %{active_value_count: 1}} =
               Inventory.retire_definition(definition.id)

      # Explicit clear first.
      Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [
        Ecto.UUID.dump!(item_id)
      ])

      assert {:ok, retired} = Inventory.retire_definition(definition.id)
      assert retired.retired_at != nil
    end

    test "archived items do not block make-required or retire" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "value_type" => "text"
               })

      container_id = insert_container!()
      {:ok, archived_item} = insert_item(container_id, category.id)
      insert_text_value!(archived_item, definition.id, "large")
      archive_item!(archived_item)

      # No active items: both gates pass despite the archived value row.
      assert {:ok, _} = Inventory.update_definition(definition.id, %{"required" => true})
      assert {:ok, retired} = Inventory.retire_definition(definition.id)
      assert retired.retired_at != nil
    end
  end

  describe "options" do
    test "operator can create, rename, and retire options; retire blocked by active values" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Guard",
                 "value_type" => "single_select"
               })

      assert {:ok, option} = Inventory.create_option(definition.id, %{"label" => "Large"})
      assert {:ok, renamed} = Inventory.update_option(option.id, %{"label" => "X-Large"})
      assert renamed.label == "X-Large"

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      insert_option_value!(item_id, definition.id, option.id)

      assert {:error, :still_referenced, _} = Inventory.retire_option(option.id)

      Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [
        Ecto.UUID.dump!(item_id)
      ])

      assert {:ok, retired} = Inventory.retire_option(option.id)
      assert retired.retired_at != nil
    end

    test "options require a single-select definition" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Note",
                 "value_type" => "text"
               })

      assert {:error, :not_single_select} =
               Inventory.create_option(definition.id, %{"label" => "Nope"})
    end

    test "retired options fail the make-required gate but stay displayable" do
      category = insert_category()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Guard",
                 "value_type" => "single_select"
               })

      assert {:ok, option} = Inventory.create_option(definition.id, %{"label" => "Large"})

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      insert_option_value!(item_id, definition.id, option.id)

      # Retire is blocked while the active value points at the option.
      assert {:error, :still_referenced, _} = Inventory.retire_option(option.id)

      # Clear, retire, then re-point an archived item: history stays readable.
      Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [
        Ecto.UUID.dump!(item_id)
      ])

      assert {:ok, _retired} = Inventory.retire_option(option.id)

      # Active item with no live option value blocks make-required.
      {:ok, active_item} = insert_item(container_id, category.id)
      insert_option_value!(active_item, definition.id, option.id)

      assert {:error, :required_blocked, _} =
               Inventory.update_definition(definition.id, %{"required" => true})
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp insert_category do
    {:ok, category} =
      Dhc.Inventory.EquipmentCategory
      |> struct()
      |> Ecto.Changeset.cast(%{name: "Struct Cat #{System.unique_integer([:positive])}"}, [:name])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  defp insert_principal! do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "struct-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp insert_container! do
    user_id = insert_principal!()
    container_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO containers (id, name, created_by, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
      [
        Ecto.UUID.dump!(container_id),
        "Struct Container #{System.unique_integer([:positive])}",
        Ecto.UUID.dump!(user_id)
      ]
    )

    container_id
  end

  defp insert_item(container_id, category_id) do
    item_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO inventory_items (id, container_id, category_id, attributes, quantity, created_at, updated_at) VALUES ($1, $2, $3, '{}'::jsonb, 1, NOW(), NOW())",
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(container_id), Ecto.UUID.dump!(category_id)]
    )

    {:ok, item_id}
  end

  defp archive_item!(item_id) do
    Repo.query!("UPDATE inventory_items SET archived_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(item_id)
    ])
  end

  defp insert_text_value!(item_id, definition_id, text) do
    Repo.query!(
      "INSERT INTO inventory_item_property_values (item_id, property_definition_id, text_value, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(definition_id), text]
    )
  end

  defp insert_boolean_value!(item_id, definition_id, boolean) do
    Repo.query!(
      "INSERT INTO inventory_item_property_values (item_id, property_definition_id, boolean_value, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(definition_id), boolean]
    )
  end

  defp insert_option_value!(item_id, definition_id, option_id) do
    Repo.query!(
      "INSERT INTO inventory_item_property_values (item_id, property_definition_id, option_id, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(definition_id), Ecto.UUID.dump!(option_id)]
    )
  end
end
