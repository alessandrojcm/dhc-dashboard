defmodule Dhc.Inventory.StructureSortTest do
  use ExUnit.Case, async: true

  alias Dhc.Inventory.PropertyDefinition
  alias Dhc.Inventory.Structure

  test "sort_definitions puts identifying positions first, then case-insensitive label" do
    zebra = %PropertyDefinition{identifying_position: nil, label: "Zebra"}
    bee = %PropertyDefinition{identifying_position: 1, label: "B"}
    aye = %PropertyDefinition{identifying_position: 0, label: "A"}
    also_a = %PropertyDefinition{identifying_position: 1, label: "a"}

    assert Structure.sort_definitions([zebra, bee, aye, also_a]) == [
             aye,
             also_a,
             bee,
             zebra
           ]
  end
end
