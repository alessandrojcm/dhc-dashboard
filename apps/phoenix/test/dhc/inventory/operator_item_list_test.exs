defmodule Dhc.Inventory.OperatorItemListTest do
  @moduledoc """
  ALE-295 (ALE-284c): the operator item list read seam.

  Proves the paginated operator read the contract exposes: viewer-shaped
  rows carrying the derived label, typed values, and availability
  projection; exact `total_count`; stable ordering with an id tie-break;
  opaque cursors bound to every filter; and the category, property, and
  archive filters. Archived items stay out of the default page and are
  reachable only through the explicit archive filter (spec ALE-280 story
  54).
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

    test "orders by slug with an id tie-break so paging is stable" do
      %{category: category, container_id: container_id} = fixture()

      slugs =
        for _ <- 1..5 do
          {:ok, item} = create_item(container_id, category.id)
          item.slug
        end

      assert {:ok, page} = Inventory.list_operator_items()
      assert Enum.map(page.items, & &1.slug) == Enum.sort(slugs)

      assert {:ok, descending} = Inventory.list_operator_items(%{"direction" => "desc"})
      assert Enum.map(descending.items, & &1.slug) == Enum.sort(slugs, :desc)
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

  describe "category filter" do
    test "filters by one or more categories" do
      %{category: swords, container_id: container_id} = fixture()
      masks = create_category!()

      {:ok, sword} = create_item(container_id, swords.id)
      {:ok, mask} = create_item(container_id, masks.id)

      assert {:ok, page} = Inventory.list_operator_items(%{"categoryId" => swords.id})
      assert Enum.map(page.items, & &1.id) == [sword.id]
      assert page.total_count == 1

      assert {:ok, both} =
               Inventory.list_operator_items(%{"categoryId" => "#{swords.id},#{masks.id}"})

      assert Enum.sort(Enum.map(both.items, & &1.id)) == Enum.sort([sword.id, mask.id])
      assert both.total_count == 2
    end

    test "an empty category filter means all categories" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, page} = Inventory.list_operator_items(%{"categoryId" => ""})
      assert Enum.map(page.items, & &1.id) == [item.id]
    end
  end

  describe "property filter" do
    test "matches a single-select option, ORing values of one definition" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, large} = Inventory.create_option(size.id, %{"label" => "Large"})
      {:ok, small} = Inventory.create_option(size.id, %{"label" => "Small"})

      {:ok, big} = create_item(container_id, category.id, %{size.id => large.id})
      {:ok, little} = create_item(container_id, category.id, %{size.id => small.id})
      {:ok, _unset} = create_item(container_id, category.id)

      assert {:ok, page} =
               Inventory.list_operator_items(%{"property" => "#{size.id}:#{large.id}"})

      assert Enum.map(page.items, & &1.id) == [big.id]
      assert page.total_count == 1

      assert {:ok, either} =
               Inventory.list_operator_items(%{
                 "property" => "#{size.id}:#{large.id},#{size.id}:#{small.id}"
               })

      assert Enum.sort(Enum.map(either.items, & &1.id)) == Enum.sort([big.id, little.id])
    end

    test "ANDs across definitions and matches boolean and text values" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean")
      {:ok, brand} = create_definition(category.id, "Brand", "text")

      {:ok, match} =
        create_item(container_id, category.id, %{sharp.id => true, brand.id => "Regenyei"})

      {:ok, _other_brand} =
        create_item(container_id, category.id, %{sharp.id => true, brand.id => "Darkwood"})

      {:ok, _blunt} =
        create_item(container_id, category.id, %{sharp.id => false, brand.id => "Regenyei"})

      assert {:ok, page} =
               Inventory.list_operator_items(%{
                 "property" => "#{sharp.id}:true,#{brand.id}:Regenyei"
               })

      assert Enum.map(page.items, & &1.id) == [match.id]
      assert page.total_count == 1
    end

    test "matches text case-insensitively and rejects a malformed pair" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      {:ok, item} = create_item(container_id, category.id, %{brand.id => "Regenyei"})

      assert {:ok, page} = Inventory.list_operator_items(%{"property" => "#{brand.id}:regenyei"})
      assert Enum.map(page.items, & &1.id) == [item.id]

      assert {:error, :invalid_property} =
               Inventory.list_operator_items(%{"property" => "not-a-pair"})
    end
  end

  describe "cursor pagination" do
    test "walks forward and back with exact counts on every page" do
      %{category: category, container_id: container_id} = fixture()

      slugs =
        for _ <- 1..12 do
          {:ok, item} = create_item(container_id, category.id)
          item.slug
        end

      sorted = Enum.sort(slugs)

      assert {:ok, first} = Inventory.list_operator_items(%{"limit" => "10"})
      assert Enum.map(first.items, & &1.slug) == Enum.take(sorted, 10)
      assert first.total_count == 12
      assert first.previous_cursor == nil
      assert is_binary(first.next_cursor)

      assert {:ok, second} =
               Inventory.list_operator_items(%{"limit" => "10", "cursor" => first.next_cursor})

      assert Enum.map(second.items, & &1.slug) == Enum.drop(sorted, 10)
      assert second.total_count == 12
      assert second.next_cursor == nil
      assert is_binary(second.previous_cursor)

      assert {:ok, back} =
               Inventory.list_operator_items(%{
                 "limit" => "10",
                 "cursor" => second.previous_cursor
               })

      assert Enum.map(back.items, & &1.slug) == Enum.take(sorted, 10)
    end

    test "a cursor from a different filter set is refused" do
      %{category: category, container_id: container_id} = fixture()
      other = create_category!()

      for _ <- 1..12, do: create_item(container_id, category.id)

      assert {:ok, page} = Inventory.list_operator_items(%{"limit" => "10"})
      assert is_binary(page.next_cursor)

      assert {:error, :bad_cursor} =
               Inventory.list_operator_items(%{
                 "limit" => "10",
                 "cursor" => page.next_cursor,
                 "categoryId" => other.id
               })

      assert {:error, :bad_cursor} =
               Inventory.list_operator_items(%{"limit" => "10", "cursor" => "not-a-cursor"})
    end

    test "rejects a limit outside the allowed set" do
      assert {:error, :invalid_limit} = Inventory.list_operator_items(%{"limit" => "7"})
      assert {:error, :invalid_limit} = Inventory.list_operator_items(%{"limit" => "1000"})
      assert {:error, :invalid_direction} = Inventory.list_operator_items(%{"direction" => "up"})
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
