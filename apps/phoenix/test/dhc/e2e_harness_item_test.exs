defmodule Dhc.E2EHarnessItemTest do
  @moduledoc """
  ALE-288 IMPL-02: round-trip for the frozen `inventoryItem` scenario.

  Seeds through `Dhc.E2EHarness` on top of the `inventoryStructure` seed
  (ids, never names): a minimal item with the slug-fallback label, a full
  item covering all four value types, a duplicate-label pair proving
  duplicates are allowed, and the composed `archived + inMaintenance`
  presets. Every seed cleans up per contract — history-free units
  hard-delete, history-bearing units archive — and the label is derived,
  never stored.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.E2EHarness
  alias Dhc.Inventory
  alias Dhc.Repo

  test "minimal item seeds, derives the slug-fallback label, and hard-deletes" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("item-#{uniq}")
    structure = seed_structure!(actor_id, uniq)
    leaf = List.last(structure.containers)

    result =
      E2EHarness.seed("inventoryItem", %{
        "categoryId" => structure.categoryId,
        "containerId" => leaf.containerId,
        "actorId" => actor_id
      })

    assert Enum.sort(Map.keys(result)) == [:categoryId, :deletable, :itemId, :label, :slug]
    assert result.slug =~ ~r/^item-\d{6,}$/
    assert result.label == "#{structure.categoryName} · #{result.slug}"
    assert result.categoryId == structure.categoryId
    assert result.deletable == true

    # The slug resolves alongside the id, and the label is derived, never stored.
    assert {:ok, by_slug} = Inventory.resolve_operator_item(result.slug)
    assert by_slug.id == result.itemId
    assert by_slug.label == result.label
    refute "label" in item_columns()

    # Notes edit keeps the slug stable.
    updated =
      E2EHarness.update_fixture("inventoryItem", result.itemId, %{
        "notes" => "E2E note",
        "actorId" => actor_id
      })

    assert updated.slug == result.slug
    assert updated.label == result.label
    assert updated.deletable == true

    assert :ok = E2EHarness.delete_fixture("inventoryItem", result.itemId)
    assert {:error, :not_found} = Inventory.resolve_operator_item(result.itemId)

    delete_structure!(structure)
  end

  test "all four value types seed with false-is-value and trimmed text" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("item-full-#{uniq}")
    structure = seed_structure!(actor_id, uniq, full_definitions())
    leaf = List.last(structure.containers)
    standard_id = option_id!(structure.definitions, "Size", "Standard")

    result =
      E2EHarness.seed("inventoryItem", %{
        "categoryId" => structure.categoryId,
        "containerId" => leaf.containerId,
        "values" => %{
          definition_id!(structure.definitions, "Maker") => "  Regenyei  ",
          definition_id!(structure.definitions, "Weight (g)") => "1.50",
          definition_id!(structure.definitions, "Club-owned") => false,
          definition_id!(structure.definitions, "Size") => standard_id
        },
        "notes" => "Chipped tip — re-check after Thursday sparring",
        "actorId" => actor_id
      })

    assert result.label == "#{structure.categoryName} · Regenyei · Standard"
    assert result.deletable == true

    assert {:ok, stored} = Inventory.resolve_operator_item(result.itemId)
    assert stored.notes == "Chipped tip — re-check after Thursday sparring"

    values = Map.new(stored.values, &{&1.definition_label, &1})
    assert values["Maker"].text == "Regenyei"
    assert Decimal.eq?(values["Weight (g)"].decimal, Decimal.new("1.50"))
    # Boolean false is a real value: the row is written and renders as No.
    assert values["Club-owned"].boolean == false
    assert values["Size"].option_label == "Standard"
    assert value_row_count(result.itemId) == 4

    assert :ok = E2EHarness.delete_fixture("inventoryItem", result.itemId)
    assert {:error, :not_found} = Inventory.resolve_operator_item(result.itemId)

    delete_structure!(structure)
  end

  test "withDuplicateLabel seeds two units with one label and deletes entry by entry" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("item-pair-#{uniq}")
    structure = seed_structure!(actor_id, uniq, full_definitions())
    leaf = List.last(structure.containers)
    standard_id = option_id!(structure.definitions, "Size", "Standard")

    values = %{
      definition_id!(structure.definitions, "Maker") => "Regenyei",
      definition_id!(structure.definitions, "Size") => standard_id,
      definition_id!(structure.definitions, "Club-owned") => true
    }

    assert %{items: [first, second], deletable: true} =
             E2EHarness.seed("inventoryItem", %{
               "categoryId" => structure.categoryId,
               "containerId" => leaf.containerId,
               "values" => values,
               "actorId" => actor_id,
               "withDuplicateLabel" => true
             })

    assert first.label == second.label
    assert first.label == "#{structure.categoryName} · Regenyei · Standard"
    assert first.itemId != second.itemId
    assert first.slug != second.slug

    assert :ok = E2EHarness.delete_fixture("inventoryItem", first.itemId)
    assert {:error, :not_found} = Inventory.resolve_operator_item(first.itemId)

    assert :ok = E2EHarness.delete_fixture("inventoryItem", second.itemId)
    assert {:error, :not_found} = Inventory.resolve_operator_item(second.itemId)

    delete_structure!(structure)
  end

  test "archived + inMaintenance compose: period opens, archive ends it, cleanup archives" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("item-preset-#{uniq}")
    structure = seed_structure!(actor_id, uniq)
    leaf = List.last(structure.containers)

    result =
      E2EHarness.seed("inventoryItem", %{
        "categoryId" => structure.categoryId,
        "containerId" => leaf.containerId,
        "actorId" => actor_id,
        "inMaintenance" => true,
        "archived" => true
      })

    assert result.deletable == false

    # The retained period is closed by the archive, not destroyed.
    assert [%{open?: false}] = Inventory.list_operator_item_maintenance_periods(result.itemId)

    # Cleanup archives (a no-op here) and asserts archived state, never row absence.
    assert :ok = E2EHarness.delete_fixture("inventoryItem", result.itemId)
    assert {:ok, archived} = Inventory.resolve_operator_item(result.itemId)
    assert archived.archived_at != nil

    # Retained history pins the structure: container teardown is blocked,
    # never cascading. The sandbox rolls the rows back.
    assert {:error, :still_referenced} =
             E2EHarness.delete_fixture("inventoryStructure", leaf.containerId)
  end

  defp seed_structure!(actor_id, uniq, definitions \\ []) do
    E2EHarness.seed("inventoryStructure", %{
      "categoryName" => "E2E Item Cat #{uniq}",
      "definitions" => definitions,
      "containerPath" => ["E2E Item Cage #{uniq}", "Rack #{uniq}"],
      "actorId" => actor_id
    })
  end

  defp full_definitions do
    [
      %{"label" => "Maker", "valueType" => "text", "identifyingPosition" => 0},
      %{
        "label" => "Size",
        "valueType" => "single_select",
        "required" => true,
        "identifyingPosition" => 1,
        "options" => [%{"label" => "Short"}, %{"label" => "Standard"}, %{"label" => "Long"}]
      },
      %{"label" => "Weight (g)", "valueType" => "decimal"},
      %{"label" => "Club-owned", "valueType" => "boolean", "required" => true}
    ]
  end

  defp definition_id!(definitions, label) do
    Enum.find_value(definitions, fn
      %{label: ^label, definitionId: id} -> id
      _ -> nil
    end) || raise "missing definition #{label}"
  end

  defp option_id!(definitions, definition_label, option_label) do
    Enum.find_value(definitions, fn
      %{label: ^definition_label, options: options} ->
        Enum.find_value(options, fn
          %{label: ^option_label, optionId: id} -> id
          _ -> nil
        end)

      _ ->
        nil
    end) || raise "missing option #{definition_label}/#{option_label}"
  end

  defp delete_structure!(structure) do
    structure.containers
    |> Enum.reverse()
    |> Enum.each(fn container ->
      assert {:ok, _} = E2EHarness.delete_fixture("inventoryStructure", container.containerId)
    end)

    assert :ok = E2EHarness.delete_fixture("inventoryStructure", structure.categoryId)
  end

  defp principal_id!(slug) do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{email: "#{slug}@example.com"})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp item_columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'inventory_items'",
        []
      )

    List.flatten(rows)
  end

  defp value_row_count(item_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM inventory_item_property_values WHERE item_id = $1", [
        Ecto.UUID.dump!(item_id)
      ])

    count
  end
end
