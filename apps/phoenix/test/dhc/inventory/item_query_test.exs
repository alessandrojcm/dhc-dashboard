defmodule Dhc.Inventory.ItemQueryTest do
  @moduledoc """
  ALE-347: the paging and filter mechanics shared by the operator item list
  and the member catalog, proven once against a minimal read model so both
  reads inherit the same parameter vocabulary, filter semantics, cursor
  binding, and exact count.
  """

  use Dhc.DataCase, async: false

  import Dhc.InventoryFixtures, only: [category_fixture: 0, container_fixture: 0]
  import Ecto.Query

  alias Dhc.AuthFixtures
  alias Dhc.Inventory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemQuery
  alias Dhc.Inventory.ItemQuery.ReadModel
  alias Dhc.Repo

  # A read model with one extra parameter that also scopes the query, so the
  # tests can see the extra value reach both the scope and the cursor.
  defp read_model do
    %ReadModel{
      param: {:mode, ["mode"], &parse_mode/1},
      scope: fn query, opts -> scope(query, opts.mode) end,
      search: fn query, q -> where(query, [i], ilike(i.slug, ^"%#{q}%")) end,
      project: fn rows -> Enum.map(rows, & &1.id) end
    }
  end

  defp parse_mode(nil), do: {:ok, :all}
  defp parse_mode("all"), do: {:ok, :all}
  defp parse_mode("none"), do: {:ok, :none}
  defp parse_mode(_other), do: {:error, :invalid_mode}

  defp scope(query, :all), do: query
  defp scope(query, :none), do: where(query, false)

  defp parse(params), do: ItemQuery.parse(params, read_model().param)
  defp list(params), do: ItemQuery.list(params, read_model())

  describe "parse/2" do
    test "defaults every common parameter and the read model's extra one" do
      assert {:ok, opts} = parse(%{})

      assert opts == %{
               limit: 25,
               sort: "slug",
               direction: "asc",
               category_ids: [],
               properties: %{},
               q: nil,
               cursor: nil,
               mode: :all
             }
    end

    test "reads string keys, atom keys, keyword lists, and the documented aliases" do
      category_id = Ecto.UUID.generate()
      definition_id = Ecto.UUID.generate()

      assert {:ok, %{limit: 10, direction: "desc", category_ids: [^category_id]}} =
               parse(%{"limit" => "10", "direction" => "desc", "categoryId" => category_id})

      assert {:ok, %{limit: 50, category_ids: [^category_id], mode: :none}} =
               parse(limit: 50, category_id: category_id, mode: "none")

      assert {:ok, %{properties: %{^definition_id => ["x"]}}} =
               parse(%{properties: "#{definition_id}:x"})
    end

    test "trims blank search and cursor to nil" do
      assert {:ok, %{q: nil, cursor: nil}} = parse(%{"q" => "   ", "cursor" => ""})
      assert {:ok, %{q: "sword"}} = parse(%{"q" => "  sword "})
    end

    test "splits comma-separated categories and accepts a list" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      assert {:ok, %{category_ids: [^a, ^b]}} = parse(%{"categoryId" => " #{a}, ,#{b}"})
      assert {:ok, %{category_ids: [^a, ^b]}} = parse(%{"categoryId" => [a, "", b]})
    end

    test "groups property values by definition, keeping each definition's values in order" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      assert {:ok, %{properties: properties}} =
               parse(%{"property" => "#{a}:Large,#{b}:true,#{a}:Small:x"})

      assert properties == %{a => ["Large", "Small:x"], b => ["true"]}
    end

    test "rejects malformed parameters with a domain reason" do
      assert {:error, :invalid_limit} = parse(%{"limit" => "7"})
      assert {:error, :invalid_direction} = parse(%{"direction" => "up"})
      assert {:error, :invalid_category} = parse(%{"categoryId" => "not-a-uuid"})
      assert {:error, :invalid_category} = parse(%{"categoryId" => 42})
      assert {:error, :invalid_property} = parse(%{"property" => "not-a-pair"})
      assert {:error, :invalid_property} = parse(%{"property" => "not-a-uuid:1"})
      assert {:error, :invalid_property} = parse(%{"property" => ["x"]})
      assert {:error, :invalid_mode} = parse(%{"mode" => "sideways"})
    end

    test "refuses a non-decimal value only on a decimal definition" do
      category = category_fixture()
      {:ok, weight} = create_definition(category.id, "Weight", "decimal")
      {:ok, brand} = create_definition(category.id, "Brand", "text")

      assert {:ok, _opts} = parse(%{"property" => "#{weight.id}:1.5"})
      assert {:ok, _opts} = parse(%{"property" => "#{brand.id}:not-a-number"})

      assert {:error, :invalid_property} =
               parse(%{"property" => "#{weight.id}:1,#{weight.id}:not-a-number"})
    end
  end

  describe "filter/2" do
    test "narrows to the given categories" do
      %{category: swords, container_id: container_id} = fixture()
      masks = category_fixture()
      {:ok, sword} = create_item(container_id, swords.id)
      {:ok, mask} = create_item(container_id, masks.id)
      {:ok, _other} = create_item(container_id, category_fixture().id)

      assert filtered_ids(%{"categoryId" => swords.id}) == [sword.id]

      assert Enum.sort(filtered_ids(%{"categoryId" => "#{swords.id},#{masks.id}"})) ==
               Enum.sort([sword.id, mask.id])
    end

    test "ORs values within one definition and ANDs across definitions" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, large} = Inventory.create_option(size.id, %{"label" => "Large"})
      {:ok, small} = Inventory.create_option(size.id, %{"label" => "Small"})
      {:ok, sharp} = create_definition(category.id, "Sharp", "boolean")

      {:ok, big_sharp} =
        create_item(container_id, category.id, %{size.id => large.id, sharp.id => true})

      {:ok, small_sharp} =
        create_item(container_id, category.id, %{size.id => small.id, sharp.id => true})

      {:ok, big_blunt} =
        create_item(container_id, category.id, %{size.id => large.id, sharp.id => false})

      either = "#{size.id}:#{large.id},#{size.id}:#{small.id}"

      assert Enum.sort(filtered_ids(%{"property" => either})) ==
               Enum.sort([big_sharp.id, small_sharp.id, big_blunt.id])

      assert Enum.sort(filtered_ids(%{"property" => "#{either},#{sharp.id}:true"})) ==
               Enum.sort([big_sharp.id, small_sharp.id])
    end

    test "matches text case-insensitively and decimals numerically" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      {:ok, weight} = create_definition(category.id, "Weight", "decimal")

      {:ok, regenyei} =
        create_item(container_id, category.id, %{brand.id => "Regenyei", weight.id => "1.0"})

      {:ok, _other} =
        create_item(container_id, category.id, %{brand.id => "Other", weight.id => "2.0"})

      assert filtered_ids(%{"property" => "#{brand.id}:regenyei"}) == [regenyei.id]
      assert filtered_ids(%{"property" => "#{weight.id}:1"}) == [regenyei.id]
      assert filtered_ids(%{"property" => "#{weight.id}:1.000"}) == [regenyei.id]
    end

    test "is a no-op without filters" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, a} = create_item(container_id, category.id)
      {:ok, b} = create_item(container_id, category.id)

      assert Enum.sort(filtered_ids(%{})) == Enum.sort([a.id, b.id])
    end
  end

  describe "list/2" do
    test "walks forward and back by slug with an exact count on every page" do
      %{category: category, container_id: container_id} = fixture()

      ids =
        for _ <- 1..12 do
          {:ok, item} = create_item(container_id, category.id)
          item
        end
        |> Enum.sort_by(& &1.slug)
        |> Enum.map(& &1.id)

      assert {:ok, first} = list(%{"limit" => "10"})
      assert first.items == Enum.take(ids, 10)
      assert first.total_count == 12
      assert first.limit == 10
      assert first.previous_cursor == nil
      assert is_binary(first.next_cursor)

      assert {:ok, second} = list(%{"limit" => "10", "cursor" => first.next_cursor})
      assert second.items == Enum.drop(ids, 10)
      assert second.total_count == 12
      assert second.next_cursor == nil

      assert {:ok, back} = list(%{"limit" => "10", "cursor" => second.previous_cursor})
      assert back.items == first.items
      assert back.next_cursor != nil

      assert {:ok, desc} = list(%{"limit" => "10", "direction" => "desc"})
      assert desc.items == ids |> Enum.reverse() |> Enum.take(10)
    end

    test "counts exactly over the scoped, filtered, and searched set" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      for _ <- 1..3, do: create_item(container_id, category_fixture().id)

      assert {:ok, %{total_count: 4}} = list(%{})
      assert {:ok, %{total_count: 1, items: [id]}} = list(%{"categoryId" => category.id})
      assert id == item.id
      assert {:ok, %{total_count: 1}} = list(%{"q" => item.slug})
      assert {:ok, %{total_count: 0, items: []}} = list(%{"mode" => "none"})
    end

    test "binds the cursor to the extra parameter and every filter" do
      %{category: category, container_id: container_id} = fixture()
      for _ <- 1..11, do: create_item(container_id, category.id)
      {:ok, first} = list(%{"limit" => "10"})
      cursor = first.next_cursor

      for mismatch <- [
            %{"limit" => "25"},
            %{"direction" => "desc"},
            %{"mode" => "none"},
            %{"categoryId" => category.id},
            %{"property" => "#{Ecto.UUID.generate()}:x"},
            %{"q" => "item"}
          ] do
        params = Map.merge(%{"limit" => "10", "cursor" => cursor}, mismatch)
        assert {:error, :bad_cursor} = list(params), "accepted #{inspect(mismatch)}"
      end

      assert {:error, :bad_cursor} = list(%{"limit" => "10", "cursor" => "not-a-cursor"})
      assert {:ok, %{items: [_last]}} = list(%{"limit" => "10", "cursor" => cursor})
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp filtered_ids(params) do
    {:ok, opts} = parse(params)

    from(i in Item, as: :item)
    |> ItemQuery.filter(opts)
    |> select([i], i.id)
    |> Repo.all()
  end

  defp fixture do
    %{category: category_fixture(), container_id: container_fixture().id}
  end

  defp create_item(container_id, category_id, values \\ %{}) do
    Inventory.create_operator_item(
      %{"container_id" => container_id, "category_id" => category_id, "values" => values},
      AuthFixtures.principal_fixture().id
    )
  end

  defp create_definition(category_id, label, value_type) do
    Inventory.create_definition(category_id, %{"label" => label, "value_type" => value_type})
  end
end
