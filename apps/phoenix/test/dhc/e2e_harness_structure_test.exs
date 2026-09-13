defmodule Dhc.E2EHarnessStructureTest do
  @moduledoc """
  ALE-288 IMPL-01: round-trip for the frozen `inventoryStructure` scenario.

  Seeds category + four value types + nested containers through
  `Dhc.E2EHarness`, asserts the frozen result shape, exercises the
  rename update path, then deletes leaf-first (containers deepest-first,
  then the category) and proves clean teardown.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.E2EHarness
  alias Dhc.Inventory
  alias Dhc.Repo

  test "seed creates category + 4 value types + nested containers and deletes cleanly" do
    uniq = System.unique_integer([:positive])
    actor_id = principal_id!("structure-#{uniq}")
    root_name = "E2E Cage #{uniq}"
    category_name = "E2E Feder #{uniq}"

    result =
      E2EHarness.seed("inventoryStructure", %{
        "categoryName" => category_name,
        "categoryDescription" => "Steel training swords",
        "definitions" => [
          %{"label" => "Maker", "valueType" => "text", "identifyingPosition" => 0},
          %{
            "label" => "Size",
            "valueType" => "single_select",
            "required" => true,
            "identifyingPosition" => 1,
            "options" => [
              %{"label" => "Short"},
              %{"label" => "Standard"},
              %{"label" => "Long"}
            ]
          },
          %{"label" => "Weight (g)", "valueType" => "decimal"},
          %{"label" => "Club-owned", "valueType" => "boolean", "required" => true}
        ],
        "containerPath" => [root_name, "Rack 2"],
        "containerDescription" => "Second rack from the door",
        "actorId" => actor_id
      })

    assert result.categoryId != nil
    assert result.categoryName == category_name
    # No legacy vocab in the result.
    refute Map.has_key?(result, :availableAttributes)
    refute Map.has_key?(result, :available_attributes)

    assert [
             %{label: "Maker", valueType: "text", identifyingPosition: 0, required: false},
             %{
               label: "Size",
               valueType: "single_select",
               identifyingPosition: 1,
               required: true
             },
             %{label: "Club-owned", valueType: "boolean", identifyingPosition: nil},
             %{label: "Weight (g)", valueType: "decimal", identifyingPosition: nil}
           ] = result.definitions

    size = Enum.find(result.definitions, &(&1.label == "Size"))

    assert [
             %{label: "Short", position: 0},
             %{label: "Standard", position: 1},
             %{label: "Long", position: 2}
           ] = size.options

    assert Enum.all?(result.definitions, &(&1.definitionId != nil))
    assert size.options |> Enum.all?(&(&1.optionId != nil))

    assert [
             %{name: ^root_name, parentContainerId: nil, path: [^root_name]},
             %{name: "Rack 2", parentContainerId: root_id, path: [^root_name, "Rack 2"]}
           ] = result.containers

    assert root_id != nil
    [root, leaf] = result.containers
    assert leaf.parentContainerId == root.containerId

    # Rename path: category + leaf container.
    renamed_category = "#{category_name} Renamed"

    updated =
      E2EHarness.update_fixture("inventoryStructure", result.categoryId, %{
        "categoryName" => renamed_category,
        "containers" => [%{"containerId" => leaf.containerId, "name" => "Rack Renamed"}]
      })

    assert updated.categoryName == renamed_category
    assert [%{containerId: updated_leaf_id, name: "Rack Renamed"}] = updated.containers
    assert updated_leaf_id == leaf.containerId

    # Teardown leaf-first, then the category.
    assert {:ok, _} = E2EHarness.delete_fixture("inventoryStructure", leaf.containerId)
    assert {:ok, _} = E2EHarness.delete_fixture("inventoryStructure", root.containerId)
    assert :ok = E2EHarness.delete_fixture("inventoryStructure", result.categoryId)

    assert {:error, :not_found} = Inventory.get_category(result.categoryId)
    assert {:error, :not_found} = Inventory.get_container(root.containerId)
    assert {:error, :not_found} = Inventory.get_container(leaf.containerId)

    for definition <- result.definitions do
      assert {:error, :not_found} = Inventory.get_definition(definition.definitionId)

      for option <- definition.options do
        assert {:error, :not_found} = Inventory.get_option(option.optionId)
      end
    end
  end

  defp principal_id!(slug) do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{email: "#{slug}@example.com"})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
