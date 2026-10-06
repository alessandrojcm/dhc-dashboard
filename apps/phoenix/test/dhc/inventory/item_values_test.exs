defmodule Dhc.Inventory.ItemValuesTest do
  @moduledoc """
  ALE-345: `Dhc.Inventory.ItemValues.invalid_stored/2` validates stored item
  property values with the same rules `validate/2` applies to supplied ones.
  """

  use Dhc.DataCase, async: true

  import Dhc.InventoryFixtures, only: [category_fixture: 0, container_fixture: 0, item_row!: 2]

  alias Dhc.Inventory
  alias Dhc.Inventory.ItemValues
  alias Dhc.Repo

  describe "invalid_stored/2" do
    setup do
      category = category_fixture()
      container_id = container_fixture().id
      %{category: category, container_id: container_id}
    end

    test "returns nothing when there are no items or no definitions", %{category: category} do
      definition = definition!(category.id, "Note", "text", required: true)

      assert ItemValues.invalid_stored([definition], []) == %{}
      assert ItemValues.invalid_stored([], [Ecto.UUID.generate()]) == %{}
    end

    test "required definitions need a stored value of every type, in batch", ctx do
      text = definition!(ctx.category.id, "Note", "text", required: true)
      decimal = definition!(ctx.category.id, "Length", "decimal", required: true)
      boolean = definition!(ctx.category.id, "Sharp", "boolean", required: true)
      select = definition!(ctx.category.id, "Guard", "single_select", required: true)
      {:ok, large} = Inventory.create_option(select.id, %{"label" => "Large"})

      definitions = ItemValues.load_definitions(ctx.category.id)

      filled = item!(ctx)
      insert_value!(filled, text.id, :text_value, "rapier")
      insert_value!(filled, decimal.id, :decimal_value, Decimal.new("0"))
      insert_value!(filled, boolean.id, :boolean_value, false)
      insert_value!(filled, select.id, :option_id, Ecto.UUID.dump!(large.id))

      empty = item!(ctx)

      partial = item!(ctx)
      insert_value!(partial, text.id, :text_value, "sabre")
      insert_value!(partial, boolean.id, :boolean_value, true)

      assert ItemValues.invalid_stored(definitions, [filled, empty, partial]) == %{
               empty => %{
                 text.id => :required,
                 decimal.id => :required,
                 boolean.id => :required,
                 select.id => :required
               },
               partial => %{decimal.id => :required, select.id => :required}
             }
    end

    test "optional definitions accept absence and present values", ctx do
      text = definition!(ctx.category.id, "Note", "text", required: false)
      decimal = definition!(ctx.category.id, "Length", "decimal", required: false)
      boolean = definition!(ctx.category.id, "Sharp", "boolean", required: false)
      select = definition!(ctx.category.id, "Guard", "single_select", required: false)
      {:ok, large} = Inventory.create_option(select.id, %{"label" => "Large"})

      definitions = ItemValues.load_definitions(ctx.category.id)

      empty = item!(ctx)
      filled = item!(ctx)
      insert_value!(filled, text.id, :text_value, "rapier")
      insert_value!(filled, decimal.id, :decimal_value, Decimal.new("-1.5"))
      insert_value!(filled, boolean.id, :boolean_value, false)
      insert_value!(filled, select.id, :option_id, Ecto.UUID.dump!(large.id))

      assert ItemValues.invalid_stored(definitions, [empty, filled]) == %{}
    end

    test "whitespace-only stored text is absence", ctx do
      required = definition!(ctx.category.id, "Note", "text", required: true)
      optional = definition!(ctx.category.id, "Remark", "text", required: false)
      definitions = ItemValues.load_definitions(ctx.category.id)

      blank = item!(ctx)
      insert_value!(blank, required.id, :text_value, "   ")
      insert_value!(blank, optional.id, :text_value, " ")

      assert ItemValues.invalid_stored(definitions, [blank]) == %{
               blank => %{required.id => :required}
             }
    end

    test "single-select values must be a live option known to the definition", ctx do
      guard = definition!(ctx.category.id, "Guard", "single_select", required: false)
      grip = definition!(ctx.category.id, "Grip", "single_select", required: true)
      {:ok, live} = Inventory.create_option(guard.id, %{"label" => "Large"})
      {:ok, retired} = Inventory.create_option(guard.id, %{"label" => "Small"})
      {:ok, leather} = Inventory.create_option(grip.id, %{"label" => "Leather"})
      {:ok, unlisted} = Inventory.create_option(grip.id, %{"label" => "Wire"})

      retired_item = item!(ctx)
      insert_value!(retired_item, guard.id, :option_id, Ecto.UUID.dump!(retired.id))
      insert_value!(retired_item, grip.id, :option_id, Ecto.UUID.dump!(leather.id))

      unknown_item = item!(ctx)
      insert_value!(unknown_item, guard.id, :option_id, Ecto.UUID.dump!(live.id))
      insert_value!(unknown_item, grip.id, :option_id, Ecto.UUID.dump!(unlisted.id))

      live_item = item!(ctx)
      insert_value!(live_item, guard.id, :option_id, Ecto.UUID.dump!(live.id))
      insert_value!(live_item, grip.id, :option_id, Ecto.UUID.dump!(leather.id))

      retire_option!(retired.id)

      # The database forbids a value pointing at another definition's option,
      # so "unknown" means absent from the definition's loaded options.
      definitions =
        ctx.category.id
        |> ItemValues.load_definitions()
        |> Enum.map(fn definition ->
          %{definition | options: Enum.reject(definition.options, &(&1.id == unlisted.id))}
        end)

      assert ItemValues.invalid_stored(definitions, [retired_item, unknown_item, live_item]) ==
               %{
                 retired_item => %{guard.id => :retired_option},
                 unknown_item => %{grip.id => :unknown_option}
               }
    end

    test "a value stored against a retired definition is rejected; absence is not", ctx do
      definition = definition!(ctx.category.id, "Old", "text", required: false)

      with_value = item!(ctx)
      insert_value!(with_value, definition.id, :text_value, "kept")
      without_value = item!(ctx)

      retire_definition!(definition.id)
      definitions = ItemValues.load_definitions(ctx.category.id)

      assert ItemValues.invalid_stored(definitions, [with_value, without_value]) == %{
               with_value => %{definition.id => :retired_definition}
             }
    end

    test "only values of the given definitions are read", ctx do
      checked = definition!(ctx.category.id, "Note", "text", required: true)
      other = definition!(ctx.category.id, "Length", "decimal", required: false)

      item = item!(ctx)
      insert_value!(item, checked.id, :text_value, "rapier")
      insert_value!(item, other.id, :decimal_value, Decimal.new("1"))

      assert ItemValues.invalid_stored([checked], [item]) == %{}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp definition!(category_id, label, value_type, required: required) do
    {:ok, definition} =
      Inventory.create_definition(category_id, %{
        "label" => label,
        "value_type" => value_type,
        "required" => required
      })

    definition
  end

  defp item!(%{category: category, container_id: container_id}),
    do: item_row!(container_id, category.id)

  defp insert_value!(item_id, definition_id, column, value)
       when column in [:text_value, :decimal_value, :boolean_value, :option_id] do
    Repo.query!(
      "INSERT INTO inventory_item_property_values (item_id, property_definition_id, #{column}, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(definition_id), value]
    )
  end

  defp retire_option!(option_id) do
    Repo.query!("UPDATE inventory_property_options SET retired_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(option_id)
    ])
  end

  defp retire_definition!(definition_id) do
    Repo.query!("UPDATE inventory_property_definitions SET retired_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(definition_id)
    ])
  end
end
