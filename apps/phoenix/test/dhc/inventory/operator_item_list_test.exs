defmodule Dhc.Inventory.OperatorItemListTest do
  @moduledoc """
  ALE-295 (ALE-284c): the operator item list read seam.

  Proves the paginated operator read the contract exposes: viewer-shaped
  rows carrying the derived label, typed values, and availability
  projection; exact `total_count`; search; and the archive filter. Archived
  items stay out of the default page and are reachable only through the
  explicit archive filter (spec ALE-280 story 54). Ordering, cursors, and
  the category and property filters are shared with the member catalog and
  proven once in `Dhc.Inventory.ItemQueryTest`.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Repo

  describe "default page" do
    test "returns active items with label, values, availability, and exact total_count" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)

      {:ok, first} = create_item(container_id, category.id, %{brand.id => "Regenyei"})
      {:ok, second} = create_item(container_id, category.id, %{brand.id => "Darkwood"})

      assert {:ok, page} = Inventory.list_operator_items()

      assert page.total_count == 2
      assert page.limit == 25
      assert page.previous_cursor == nil
      assert page.next_cursor == nil

      assert Enum.map(page.items, & &1.id) == [first.id, second.id]

      [listed | _] = page.items
      assert listed.slug == first.slug
      assert listed.label == "#{category.name} · Regenyei"
      assert listed.availability == %{available?: true, status: :available}
      assert [%{definition_label: "Brand", text: "Regenyei"}] = listed.values
      assert listed.category["name"] == category.name
      assert listed.container["id"] == container_id
      assert Enum.map(page.items, & &1.slug) == [first.slug, second.slug]
    end

    test "projects availability from maintenance and archive state, never a stored flag" do
      %{category: category, container_id: container_id} = fixture()
      actor = principal_id()

      {:ok, available} = create_item(container_id, category.id)
      {:ok, serviced} = create_item(container_id, category.id)

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 serviced.slug,
                 %{"reason" => "Bent"},
                 actor
               )

      assert {:ok, page} = Inventory.list_operator_items()

      statuses = Map.new(page.items, &{&1.id, &1.availability})

      assert statuses[available.id] == %{available?: true, status: :available}
      assert statuses[serviced.id] == %{available?: false, status: :maintenance}
    end
  end

  describe "archive filter" do
    test "hides archived items by default and reveals them only on request" do
      %{category: category, container_id: container_id} = fixture()
      actor = principal_id()

      {:ok, active} = create_item(container_id, category.id)
      {:ok, retired} = create_item(container_id, category.id)

      assert {:ok, _} = Inventory.archive_operator_item(retired.slug, %{}, actor)

      assert {:ok, default_page} = Inventory.list_operator_items()
      assert Enum.map(default_page.items, & &1.id) == [active.id]
      assert default_page.total_count == 1

      assert {:ok, archived_page} = Inventory.list_operator_items(%{"archived" => "only"})
      assert Enum.map(archived_page.items, & &1.id) == [retired.id]
      assert archived_page.total_count == 1
      assert [%{availability: %{status: :archived}}] = archived_page.items

      assert {:ok, all} = Inventory.list_operator_items(%{"archived" => "include"})
      assert Enum.sort(Enum.map(all.items, & &1.id)) == Enum.sort([active.id, retired.id])
      assert all.total_count == 2
    end

    test "rejects an unknown archive filter instead of silently ignoring it" do
      assert {:error, :invalid_archived} = Inventory.list_operator_items(%{"archived" => "yes"})
    end
  end

  describe "search" do
    test "matches every operator-visible item fact case-insensitively" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, weight} = create_definition(category.id, "Weight", "decimal")
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean")
      {:ok, large} = Inventory.create_option(size.id, %{"label" => "Searchable Large"})

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "notes" => "Reserved for beginners",
            "values" => %{
              brand.id => "Searchable Regenyei",
              size.id => large.id,
              weight.id => "1.75",
              sharp.id => true
            }
          },
          principal_id()
        )

      for q <- [
            item.slug,
            String.downcase(category.name),
            "searchable regenyei",
            "searchable large",
            "1.75",
            "Yes",
            "BEGINNERS"
          ] do
        assert {:ok, page} = Inventory.list_operator_items(%{"q" => q})
        assert Enum.map(page.items, & &1.id) == [item.id]
        assert page.total_count == 1
      end
    end

    test "matches the container name and treats blank search as no search" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, container} = Inventory.get_container(container_id)

      assert {:ok, by_container} = Inventory.list_operator_items(%{"q" => container.name})
      assert Enum.map(by_container.items, & &1.id) == [item.id]

      for blank <- ["", "   "] do
        assert {:ok, page} = Inventory.list_operator_items(%{"q" => blank})
        assert Enum.map(page.items, & &1.id) == [item.id]
      end
    end

    test "matches an ancestor container name, not just the direct container" do
      category = create_category!()
      actor = principal_id()

      {:ok, root} = Inventory.create_container(%{"name" => "Armoury"}, actor)

      {:ok, shelf} =
        Inventory.create_container(%{"name" => "Shelf", "parentContainerId" => root.id}, actor)

      other = create_container!()
      {:ok, nested} = create_item(shelf.id, category.id)
      {:ok, _elsewhere} = create_item(other.id, category.id)

      for q <- ["Armoury", "armoury shelf", "Armou"] do
        assert {:ok, page} = Inventory.list_operator_items(%{"q" => q})
        assert Enum.map(page.items, & &1.id) == [nested.id]
        assert page.total_count == 1
      end
    end

    test "matches a multi-word query that spans category and a property value" do
      %{container_id: container_id} = fixture()
      {:ok, category} = Inventory.create_category(%{"name" => "Longsword"})
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)
      {:ok, match} = create_item(container_id, category.id, %{brand.id => "Regenyei"})
      {:ok, _other} = create_item(container_id, category.id, %{brand.id => "Darkwood"})

      assert {:ok, page} = Inventory.list_operator_items(%{"q" => "Longsword Regenyei"})
      assert Enum.map(page.items, & &1.id) == [match.id]
      assert page.total_count == 1
    end

    test "matches a partial word via prefix fallback" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)
      {:ok, item} = create_item(container_id, category.id, %{brand.id => "Regenyei"})

      assert {:ok, page} = Inventory.list_operator_items(%{"q" => "Regen"})
      assert Enum.map(page.items, & &1.id) == [item.id]
      assert page.total_count == 1
    end

    test "returns no rows when the query matches nothing" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, _item} = create_item(container_id, category.id)

      assert {:ok, page} = Inventory.list_operator_items(%{"q" => "CompletelyUnknownBrandxyz"})
      assert page.items == []
      assert page.total_count == 0
    end

    test "does not match a later prefix alone when an earlier term is absent" do
      %{container_id: container_id} = fixture()
      {:ok, category} = Inventory.create_category(%{"name" => "Longsword"})
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)
      {:ok, _item} = create_item(container_id, category.id, %{brand.id => "Regenyei"})

      assert {:ok, page} = Inventory.list_operator_items(%{"q" => "Rapier Regen"})
      assert page.items == []
      assert page.total_count == 0
    end

    test "does not raise on quotes, operators, stop words, or punctuation-only queries" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, _item} = create_item(container_id, category.id)

      for q <- ["\"foo", "a & b | !c", "the", "!!!"] do
        assert {:ok, _page} = Inventory.list_operator_items(%{"q" => q})
      end
    end

    test "matches a boolean identifying value via the derived-label vocabulary" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean", identifying_position: 0)
      {:ok, yes} = create_item(container_id, category.id, %{sharp.id => true})
      {:ok, _no} = create_item(container_id, category.id, %{sharp.id => false})

      assert {:ok, page} = Inventory.list_operator_items(%{"q" => "Yes"})
      assert Enum.map(page.items, & &1.id) == [yes.id]
      assert page.total_count == 1
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture do
    %{category: create_category!(), container_id: create_container!().id}
  end

  defp create_item(container_id, category_id, values \\ %{}) do
    Inventory.create_operator_item(
      %{"container_id" => container_id, "category_id" => category_id, "values" => values},
      principal_id()
    )
  end

  defp create_definition(category_id, label, value_type, opts \\ []) do
    attrs = %{"label" => label, "value_type" => value_type}

    attrs =
      Enum.reduce(opts, attrs, fn
        {:required, required}, acc -> Map.put(acc, "required", required)
        {:identifying_position, position}, acc -> Map.put(acc, "identifying_position", position)
      end)

    Inventory.create_definition(category_id, attrs)
  end

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "List category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "List container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "operator-item-list-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
