defmodule Dhc.Inventory.OperatorItemsTest do
  @moduledoc """
  ALE-293 (ALE-284a): operator item domain seam.

  Proves slug minting and resolution, the server-derived label, typed
  value validation against definitions reloaded in the same transaction,
  atomic category change, and plain-text notes through `Dhc.Inventory`.
  Direct SQL only proves what the seam cannot express: the surviving
  legacy columns stay untouched and no `inventory_history` row is written.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Repo

  describe "slug and resolution" do
    test "mints an immutable human-readable slug and resolves by slug or id" do
      %{category: category, container_id: container_id} = fixture()

      assert {:ok, item} =
               Inventory.create_operator_item(
                 %{"container_id" => container_id, "category_id" => category.id},
                 principal_id()
               )

      assert item.slug =~ ~r/^item-\d{6,}$/

      assert {:ok, by_slug} = Inventory.resolve_operator_item(item.slug)
      assert by_slug.id == item.id

      assert {:ok, by_id} = Inventory.resolve_operator_item(item.id)
      assert by_id.slug == item.slug

      assert {:error, :not_found} = Inventory.resolve_operator_item("item-999999")
      assert {:error, :not_found} = Inventory.resolve_operator_item(Ecto.UUID.generate())
    end

    test "slugs are unique and monotonic across items" do
      %{category: category, container_id: container_id} = fixture()

      slugs =
        for _ <- 1..3 do
          {:ok, item} = create_item(container_id, category.id)
          item.slug
        end

      assert slugs == Enum.uniq(slugs)
      assert slugs == Enum.sort(slugs)
    end

    test "the slug survives a category change" do
      %{category: category, container_id: container_id} = fixture()
      other = create_category!()

      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, reclassified} =
               Inventory.change_operator_item_category(
                 item.id,
                 %{"category_id" => other.id, "values" => %{}},
                 principal_id()
               )

      assert reclassified.category_id == other.id
      assert reclassified.slug == item.slug
    end
  end

  describe "derived label" do
    test "derives from the category plus its ordered identifying definitions" do
      %{category: category, container_id: container_id} = fixture()

      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)

      {:ok, size} =
        create_definition(category.id, "Size", "single_select", identifying_position: 1)

      {:ok, large} = Inventory.create_option(size.id, %{"label" => "Large"})
      {:ok, _plain} = create_definition(category.id, "Sharp", "boolean")

      assert {:ok, item} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{brand.id => "Regenyei", size.id => large.id}
                 },
                 principal_id()
               )

      assert item.label == "#{category.name} · Regenyei · Large"
    end

    test "falls back to the slug when no identifying value is present" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, _brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)

      {:ok, item} = create_item(container_id, category.id)

      assert item.label == "#{category.name} · #{item.slug}"
    end

    test "renders boolean and decimal identifying values without storing the label" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean", identifying_position: 0)

      {:ok, weight} =
        create_definition(category.id, "Weight", "decimal", identifying_position: 1)

      assert {:ok, item} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{sharp.id => false, weight.id => "1.50"}
                 },
                 principal_id()
               )

      assert item.label == "#{category.name} · No · 1.50"

      # The label is derived, never stored: no column holds it.
      refute "label" in item_columns()
    end
  end

  describe "typed values on create" do
    test "stores each value type and projects it back through the seam" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      {:ok, weight} = create_definition(category.id, "Weight", "decimal")
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean")
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, large} = Inventory.create_option(size.id, %{"label" => "Large"})

      assert {:ok, item} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{
                     brand.id => "Regenyei",
                     weight.id => "1.5",
                     sharp.id => true,
                     size.id => large.id
                   }
                 },
                 principal_id()
               )

      values = Map.new(item.values, &{&1.definition_id, &1})

      assert values[brand.id].text == "Regenyei"
      assert Decimal.equal?(values[weight.id].decimal, Decimal.new("1.5"))
      assert values[sharp.id].boolean == true
      assert values[size.id].option_id == large.id
      assert values[size.id].option_label == "Large"
    end

    test "empty text is absence while boolean false is a real value" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean")

      assert {:ok, item} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{brand.id => "   ", sharp.id => false}
                 },
                 principal_id()
               )

      definition_ids = Enum.map(item.values, & &1.definition_id)

      refute brand.id in definition_ids
      assert sharp.id in definition_ids
      assert value_row_count(item.id) == 1
    end

    test "reports per-definition errors for requiredness, type, and option membership" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", required: true)
      {:ok, weight} = create_definition(category.id, "Weight", "decimal")
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, _large} = Inventory.create_option(size.id, %{"label" => "Large"})
      other_category = create_category!()
      {:ok, foreign} = create_definition(other_category.id, "Foreign", "text")

      assert {:error, :invalid_values, errors} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{
                     brand.id => "",
                     weight.id => "heavy",
                     size.id => Ecto.UUID.generate(),
                     foreign.id => "nope"
                   }
                 },
                 principal_id()
               )

      assert errors[brand.id] == :required
      assert errors[weight.id] == :type_mismatch
      assert errors[size.id] == :unknown_option
      assert errors[foreign.id] == :unknown_definition
    end

    test "rejects an option that belongs to another definition and a retired option" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, guard} = create_definition(category.id, "Guard", "single_select")
      {:ok, guard_option} = Inventory.create_option(guard.id, %{"label" => "Compound"})
      {:ok, retired_option} = Inventory.create_option(size.id, %{"label" => "Small"})
      {:ok, _} = Inventory.retire_option(retired_option.id)

      assert {:error, :invalid_values, %{}} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{size.id => guard_option.id}
                 },
                 principal_id()
               )
               |> tap(fn {:error, :invalid_values, errors} ->
                 assert errors[size.id] == :unknown_option
               end)

      assert {:error, :invalid_values, errors} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{size.id => retired_option.id}
                 },
                 principal_id()
               )

      assert errors[size.id] == :retired_option
    end

    test "a concurrent option retirement cannot land between validation and insert" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, option} = Inventory.create_option(size.id, %{"label" => "Large"})
      actor = principal_id()

      # `Structure.retire_option/1` locks the option FOR UPDATE. The create
      # path share-locks the same row while validating, so the retirement must
      # wait for the create to commit rather than slipping in behind it.
      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
          Inventory.retire_option(option.id)
        end)

      result =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "values" => %{size.id => option.id}
          },
          actor
        )

      Task.await(task)

      # Either the create wins (and stores a then-live option) or it is
      # rejected — never a committed active value pointing at a retired option.
      case result do
        {:ok, item} ->
          assert [%{option_id: stored, option_label: "Large"}] = item.values
          assert stored == option.id

        {:error, :invalid_values, errors} ->
          assert errors[size.id] in [:retired_option, :unknown_option]
      end
    end

    test "rejects a value for a retired definition" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      {:ok, _} = Inventory.retire_definition(brand.id)

      assert {:error, :invalid_values, errors} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "values" => %{brand.id => "Regenyei"}
                 },
                 principal_id()
               )

      assert errors[brand.id] == :retired_definition
    end

    test "allows duplicate category and property combinations" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)

      attrs = %{
        "container_id" => container_id,
        "category_id" => category.id,
        "values" => %{brand.id => "Regenyei"}
      }

      assert {:ok, first} = Inventory.create_operator_item(attrs, principal_id())
      assert {:ok, second} = Inventory.create_operator_item(attrs, principal_id())

      assert first.slug != second.slug
      assert first.label == second.label
    end

    test "requires an active container and category" do
      %{category: category, container_id: container_id} = fixture()
      archived_container = create_container!()
      {:ok, _} = Inventory.archive_container(archived_container.id)

      assert {:error, :not_found} =
               Inventory.create_operator_item(
                 %{"container_id" => Ecto.UUID.generate(), "category_id" => category.id},
                 principal_id()
               )

      assert {:error, :archived_container} =
               Inventory.create_operator_item(
                 %{"container_id" => archived_container.id, "category_id" => category.id},
                 principal_id()
               )

      assert {:error, :not_found} =
               Inventory.create_operator_item(
                 %{"container_id" => container_id, "category_id" => Ecto.UUID.generate()},
                 principal_id()
               )
    end
  end

  describe "edit" do
    test "replaces the supplied values and keeps notes as plain current facts" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean")

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "notes" => "Chipped tip",
            "values" => %{brand.id => "Regenyei", sharp.id => true}
          },
          principal_id()
        )

      assert item.notes == "Chipped tip"

      assert {:ok, edited} =
               Inventory.update_operator_item(
                 item.id,
                 %{"notes" => "Repaired", "values" => %{brand.id => "Ensifer"}},
                 principal_id()
               )

      assert edited.notes == "Repaired"

      values = Map.new(edited.values, &{&1.definition_id, &1})
      assert values[brand.id].text == "Ensifer"
      # Omitted definitions become absent: values is the complete set.
      refute Map.has_key?(values, sharp.id)
      assert value_row_count(item.id) == 1
    end

    test "leaves values untouched when the edit omits them" do
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

      assert {:ok, edited} =
               Inventory.update_operator_item(item.id, %{"notes" => "Fine"}, principal_id())

      assert [%{definition_id: definition_id, text: "Regenyei"}] = edited.values
      assert definition_id == brand.id
    end

    test "clearing text to empty removes the value row" do
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

      assert {:ok, edited} =
               Inventory.update_operator_item(
                 item.id,
                 %{"values" => %{brand.id => ""}},
                 principal_id()
               )

      assert edited.values == []
      assert value_row_count(item.id) == 0
    end

    test "rejects an edit that violates a required definition and writes nothing" do
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

      {:ok, _} = Inventory.update_definition(brand.id, %{"required" => true})

      assert {:error, :invalid_values, errors} =
               Inventory.update_operator_item(
                 item.id,
                 %{"notes" => "changed", "values" => %{brand.id => ""}},
                 principal_id()
               )

      assert errors[brand.id] == :required

      assert {:ok, unchanged} = Inventory.resolve_operator_item(item.id)
      assert unchanged.notes == nil
      assert [%{text: "Regenyei"}] = unchanged.values
    end

    test "rejects non-textual notes instead of silently dropping them" do
      %{category: category, container_id: container_id} = fixture()

      assert {:error, :invalid_notes} =
               Inventory.create_operator_item(
                 %{
                   "container_id" => container_id,
                   "category_id" => category.id,
                   "notes" => %{"structured" => "nope"}
                 },
                 principal_id()
               )

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "notes" => "Chipped tip"
          },
          principal_id()
        )

      assert {:error, :invalid_notes} =
               Inventory.update_operator_item(item.id, %{"notes" => 42}, principal_id())

      # The rejected edit left the stored note intact.
      assert {:ok, %{notes: "Chipped tip"}} = Inventory.resolve_operator_item(item.id)

      # Explicit empty text still clears it.
      assert {:ok, %{notes: nil}} =
               Inventory.update_operator_item(item.id, %{"notes" => "  "}, principal_id())
    end

    test "is not a movement command: containerId in an edit is ignored" do
      %{category: category, container_id: container_id} = fixture()
      other_container = create_container!()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, edited} =
               Inventory.update_operator_item(
                 item.id,
                 %{"container_id" => other_container.id, "notes" => "still home"},
                 principal_id()
               )

      assert edited.container_id == container_id
    end

    test "rejects edits to an archived item" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      archive_item!(item.id)

      assert {:error, :archived} =
               Inventory.update_operator_item(item.id, %{"notes" => "nope"}, principal_id())
    end
  end

  describe "category change" do
    test "atomically supplies every value the new category requires" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, old_brand} = create_definition(category.id, "Brand", "text")

      target = create_category!()
      {:ok, new_brand} = create_definition(target.id, "Brand", "text", required: true)
      {:ok, new_size} = create_definition(target.id, "Size", "text")

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "values" => %{old_brand.id => "Regenyei"}
          },
          principal_id()
        )

      assert {:ok, reclassified} =
               Inventory.change_operator_item_category(
                 item.id,
                 %{
                   "category_id" => target.id,
                   # Explicit operator mapping of the old value onto the new definition.
                   "values" => %{new_brand.id => "Regenyei", new_size.id => "Large"}
                 },
                 principal_id()
               )

      assert reclassified.category_id == target.id

      values = Map.new(reclassified.values, &{&1.definition_id, &1.text})
      assert values == %{new_brand.id => "Regenyei", new_size.id => "Large"}

      # Old-category values that were not mapped cease to be current facts.
      assert value_row_count(item.id) == 2
    end

    test "partial reclassification is impossible" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, old_brand} = create_definition(category.id, "Brand", "text")

      target = create_category!()
      {:ok, required_definition} = create_definition(target.id, "Serial", "text", required: true)

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "values" => %{old_brand.id => "Regenyei"}
          },
          principal_id()
        )

      assert {:error, :invalid_values, errors} =
               Inventory.change_operator_item_category(
                 item.id,
                 %{"category_id" => target.id, "values" => %{}},
                 principal_id()
               )

      assert errors[required_definition.id] == :required

      assert {:ok, unchanged} = Inventory.resolve_operator_item(item.id)
      assert unchanged.category_id == category.id
      assert [%{definition_id: definition_id, text: "Regenyei"}] = unchanged.values
      assert definition_id == old_brand.id
    end

    test "rejects an unknown or archived target category" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:error, :not_found} =
               Inventory.change_operator_item_category(
                 item.id,
                 %{"category_id" => Ecto.UUID.generate(), "values" => %{}},
                 principal_id()
               )

      archived = create_category!()
      archive_category!(archived.id)

      assert {:error, :archived_category} =
               Inventory.change_operator_item_category(
                 item.id,
                 %{"category_id" => archived.id, "values" => %{}},
                 principal_id()
               )
    end
  end

  describe "legacy columns are ignored by target paths" do
    test "never writes inventory_history and leaves legacy item columns alone" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "notes" => "target only",
            "values" => %{brand.id => "Regenyei"}
          },
          principal_id()
        )

      {:ok, _} =
        Inventory.update_operator_item(
          item.id,
          %{"notes" => "still target only", "values" => %{brand.id => "Ensifer"}},
          principal_id()
        )

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM inventory_history WHERE item_id = $1", [
                 Ecto.UUID.dump!(item.id)
               ])

      assert %{rows: [[quantity, photo_url, attributes, out_for_maintenance]]} =
               Repo.query!(
                 """
                 SELECT quantity, photo_url, attributes, out_for_maintenance
                 FROM inventory_items WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(item.id)]
               )

      # `quantity` is server-set to 1 only to satisfy the surviving NOT NULL
      # until ALE-289 removes it.
      assert quantity == 1
      assert photo_url == nil
      assert attributes == %{}
      assert out_for_maintenance == false
    end

    test "the minted slug is rejected as a duplicate by the database" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, first} = create_item(container_id, category.id)
      {:ok, second} = create_item(container_id, category.id)

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE inventory_items SET slug = $1 WHERE id = $2", [
          first.slug,
          Ecto.UUID.dump!(second.id)
        ])
      end
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

  defp create_definition(category_id, label, value_type, opts \\ []) do
    attrs = %{"label" => label, "value_type" => value_type}

    attrs =
      opts
      |> Enum.reduce(attrs, fn
        {:required, required}, acc -> Map.put(acc, "required", required)
        {:identifying_position, position}, acc -> Map.put(acc, "identifying_position", position)
      end)

    Inventory.create_definition(category_id, attrs)
  end

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Item category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Item container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "operator-items-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp archive_item!(item_id) do
    Repo.query!("UPDATE inventory_items SET archived_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(item_id)
    ])
  end

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
