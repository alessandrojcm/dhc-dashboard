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

  describe "availability filter" do
    test "filters the whole list before paging, with an exact count" do
      %{category: category, container_id: container_id} = fixture()
      actor = principal_id()

      items = for _ <- 1..23, do: elem(create_item(container_id, category.id), 1)

      # Every third item is under maintenance, so they sit on every page of
      # the unfiltered list.
      serviced =
        items
        |> Enum.take_every(3)
        |> Enum.map(fn item ->
          {:ok, _} =
            Inventory.start_operator_item_maintenance(item.slug, %{"reason" => "Bent"}, actor)

          item.id
        end)

      assert {:ok, %{items: everything}} = Inventory.list_operator_items(%{"limit" => "100"})
      in_order = Enum.map(everything, & &1.id)

      params = %{"availability" => "maintenance", "limit" => "10"}
      assert {:ok, first} = Inventory.list_operator_items(params)
      assert first.total_count == 8
      assert first.next_cursor == nil
      assert Enum.map(first.items, & &1.id) == Enum.filter(in_order, &(&1 in serviced))
      assert Enum.all?(first.items, &(&1.availability.status == :maintenance))

      assert {:ok, available} =
               Inventory.list_operator_items(%{"availability" => "available", "limit" => "10"})

      assert available.total_count == 15
      assert Enum.count(available.items) == 10

      assert {:ok, rest} =
               Inventory.list_operator_items(%{
                 "availability" => "available",
                 "limit" => "10",
                 "cursor" => available.next_cursor
               })

      assert rest.total_count == 15
      assert rest.next_cursor == nil
      listed = Enum.map(available.items ++ rest.items, & &1.id)
      assert listed == in_order -- serviced
    end

    test "selects each status by the projection's precedence, alone or combined" do
      %{category: category, container_id: container_id} = fixture()
      actor = principal_id()

      {:ok, free} = create_item(container_id, category.id)
      {:ok, serviced} = create_item(container_id, category.id)
      {:ok, borrowed} = create_item(container_id, category.id)
      {:ok, serviced_and_borrowed} = create_item(container_id, category.id)
      {:ok, requested} = create_item(container_id, category.id)
      {:ok, retired} = create_item(container_id, category.id)

      for item <- [serviced, serviced_and_borrowed] do
        {:ok, _} =
          Inventory.start_operator_item_maintenance(item.slug, %{"reason" => "Bent"}, actor)
      end

      create_loan!(borrowed, principal_id(), "checked_out")
      create_loan!(serviced_and_borrowed, principal_id(), "approved")
      # A pending request is not an availability input.
      create_loan!(requested, principal_id(), "requested")
      {:ok, _} = Inventory.archive_operator_item(retired.slug, %{}, actor)

      expectations = [
        {"available", [free, requested], :available},
        {"maintenance", [serviced, serviced_and_borrowed], :maintenance},
        {"on_loan", [borrowed], :on_loan}
      ]

      for {filter, expected, status} <- expectations,
          archived <- ["exclude", "include"] do
        assert {:ok, page} =
                 Inventory.list_operator_items(%{
                   "availability" => filter,
                   "archived" => archived
                 })

        assert ids(page) == ids(expected), "#{filter} with archived=#{archived}"
        assert page.total_count == length(expected)
        assert Enum.all?(page.items, &(&1.availability.status == status))
      end

      assert {:ok, combined} =
               Inventory.list_operator_items(%{"availability" => " on_loan, available ,"})

      assert ids(combined) == ids([free, borrowed, requested])
      assert combined.total_count == 3

      for blank <- [nil, ""] do
        assert {:ok, all} =
                 Inventory.list_operator_items(%{
                   "availability" => blank,
                   "archived" => "include"
                 })

        assert all.total_count == 6
      end

      # Archived items are only ever reached through `archived`.
      assert {:ok, %{items: [], total_count: 0}} =
               Inventory.list_operator_items(%{
                 "availability" => "available,maintenance,on_loan",
                 "archived" => "only"
               })
    end

    test "binds the cursor to the availability filter" do
      %{category: category, container_id: container_id} = fixture()
      for _ <- 1..11, do: create_item(container_id, category.id)

      assert {:ok, %{next_cursor: unfiltered}} =
               Inventory.list_operator_items(%{"limit" => "10"})

      assert {:ok, %{next_cursor: filtered}} =
               Inventory.list_operator_items(%{"limit" => "10", "availability" => "available"})

      assert {:error, :bad_cursor} =
               Inventory.list_operator_items(%{
                 "limit" => "10",
                 "cursor" => unfiltered,
                 "availability" => "available"
               })

      assert {:error, :bad_cursor} =
               Inventory.list_operator_items(%{
                 "limit" => "10",
                 "cursor" => filtered,
                 "availability" => "available,on_loan"
               })

      # The order of the subset does not change the result set.
      assert {:ok, %{next_cursor: reordered}} =
               Inventory.list_operator_items(%{
                 "limit" => "10",
                 "availability" => "on_loan,available"
               })

      assert {:ok, %{items: [_last]}} =
               Inventory.list_operator_items(%{
                 "limit" => "10",
                 "cursor" => reordered,
                 "availability" => "available,on_loan"
               })
    end

    test "refuses an unknown availability, including archived" do
      for raw <- ["archived", "unavailable", "all", "available,lost", 42] do
        assert {:error, :invalid_availability} =
                 Inventory.list_operator_items(%{"availability" => raw}),
               "accepted #{inspect(raw)}"
      end
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

  defp ids(items) when is_list(items), do: items |> Enum.map(& &1.id) |> Enum.sort()
  defp ids(%{items: items}), do: ids(items)

  # Loan rows are fixtures for the list read; a loan inserted directly can
  # also hold an item under maintenance, which the loan commands refuse.
  defp create_loan!(item, borrower_id, status) do
    Repo.query!(
      """
      INSERT INTO inventory_loans (
        item_id, borrower_principal_id, status,
        requested_start_on, requested_due_on,
        item_slug_snapshot, item_label_snapshot,
        created_at, updated_at
      )
      VALUES ($1, $2, $3, CURRENT_DATE, CURRENT_DATE + 7, $4, $5, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(item.id),
        Ecto.UUID.dump!(borrower_id),
        status,
        item.slug,
        item.label || item.slug
      ]
    )
  end
end
