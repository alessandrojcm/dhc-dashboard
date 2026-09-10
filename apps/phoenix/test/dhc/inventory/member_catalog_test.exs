defmodule Dhc.Inventory.MemberCatalogTest do
  @moduledoc """
  ALE-285: the member catalog read seam.

  The privacy assertions are the point of this suite, not a footnote: a
  member row must never carry the container, operator notes, or an operator
  maintenance fact, and an unavailable item must explain itself with a
  generic reason that cannot identify a borrower (spec ALE-280 stories 29,
  45; ALE-275 resolution). The browse mechanics — search over the derived
  label's ingredients, category and property filters, stable slug ordering,
  cursor pagination with exact counts — are proven alongside them because a
  filter that silently widens the set is also a privacy risk.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Repo

  describe "privacy" do
    test "a member row carries only label, slug, category, values, and availability" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "notes" => "Handle is loose — quartermaster only",
            "values" => %{brand.id => "Regenyei"}
          },
          principal_id()
        )

      assert {:ok, page} = Inventory.list_catalog_items()
      assert [row] = page.items

      assert Enum.sort(Map.keys(row)) ==
               Enum.sort([:id, :slug, :label, :category, :values, :availability])

      assert row.id == item.id
      assert row.slug == item.slug
      assert row.label == "#{category.name} · Regenyei"
      assert row.category == %{id: category.id, name: category.name}
      assert [%{definition_label: "Brand", text: "Regenyei"}] = row.values
    end

    test "an item on loan reports a generic reason and never the borrower" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      borrower = principal_id()

      create_loan!(item, borrower, "checked_out")

      assert {:ok, page} = Inventory.list_catalog_items()
      assert [%{availability: availability} = row] = page.items

      assert availability == %{available?: false, reason: :on_loan}

      # Nothing in the row may identify the borrower or their loan.
      refute row |> inspect() |> String.contains?(borrower)
    end

    test "an item in maintenance reports only the generic reason, never the operator note" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent in sparring"},
                 principal_id()
               )

      assert {:ok, page} = Inventory.list_catalog_items()
      assert [row] = page.items

      assert row.availability == %{available?: false, reason: :maintenance}
      refute row |> inspect() |> String.contains?("bent")
    end

    test "archived items are absent from the catalog and unresolvable" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, active} = create_item(container_id, category.id)
      {:ok, retired} = create_item(container_id, category.id)

      assert {:ok, _} = Inventory.archive_operator_item(retired.slug, %{}, principal_id())

      assert {:ok, page} = Inventory.list_catalog_items()
      assert Enum.map(page.items, & &1.id) == [active.id]
      assert page.total_count == 1

      # Reported as absent, not as "archived": a member must not learn an
      # operator fact about an item they cannot see.
      assert {:error, :not_found} = Inventory.resolve_catalog_item(retired.slug)
    end

    test "there is no archive filter to opt into" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      {:ok, retired} = create_item(container_id, category.id)
      assert {:ok, _} = Inventory.archive_operator_item(retired.slug, %{}, principal_id())

      for attempt <- [%{"archived" => "only"}, %{"archived" => "include"}] do
        assert {:ok, page} = Inventory.list_catalog_items(attempt)
        assert Enum.map(page.items, & &1.id) == [item.id]
      end
    end
  end

  describe "resolve" do
    test "resolves one item by slug or id with the member shape" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, by_slug} = Inventory.resolve_catalog_item(item.slug)
      assert by_slug.id == item.id
      assert by_slug.availability == %{available?: true, reason: :available}

      assert {:ok, by_id} = Inventory.resolve_catalog_item(item.id)
      assert by_id.slug == item.slug

      assert {:error, :not_found} = Inventory.resolve_catalog_item("item-999999")
    end
  end

  describe "search" do
    test "matches the derived label through its ingredients" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)

      {:ok, regenyei} = create_item(container_id, category.id, %{brand.id => "Regenyei"})
      {:ok, darkwood} = create_item(container_id, category.id, %{brand.id => "Darkwood"})

      assert {:ok, page} = Inventory.list_catalog_items(%{"q" => "regen"})
      assert Enum.map(page.items, & &1.id) == [regenyei.id]
      assert page.total_count == 1

      # The category name is the other half of the derived label.
      assert {:ok, by_category} = Inventory.list_catalog_items(%{"q" => category.name})

      assert Enum.sort(Enum.map(by_category.items, & &1.id)) ==
               Enum.sort([regenyei.id, darkwood.id])
    end

    test "matches the immutable slug and single-select option labels" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, size} = create_definition(category.id, "Size", "single_select")
      {:ok, large} = Inventory.create_option(size.id, %{"label" => "Large"})

      {:ok, big} = create_item(container_id, category.id, %{size.id => large.id})
      {:ok, _plain} = create_item(container_id, category.id)

      assert {:ok, by_option} = Inventory.list_catalog_items(%{"q" => "larg"})
      assert Enum.map(by_option.items, & &1.id) == [big.id]

      assert {:ok, by_slug} = Inventory.list_catalog_items(%{"q" => big.slug})
      assert Enum.map(by_slug.items, & &1.id) == [big.id]
    end

    test "treats LIKE metacharacters as literal text" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text")
      {:ok, discounted} = create_item(container_id, category.id, %{brand.id => "50% off"})
      {:ok, _other} = create_item(container_id, category.id, %{brand.id => "Regenyei"})

      assert {:ok, page} = Inventory.list_catalog_items(%{"q" => "50%"})
      assert Enum.map(page.items, & &1.id) == [discounted.id]

      # A bare wildcard is a search for a percent sign, not for everything.
      assert {:ok, wildcard} = Inventory.list_catalog_items(%{"q" => "%"})
      assert Enum.map(wildcard.items, & &1.id) == [discounted.id]

      # Same for the single-character wildcard.
      assert {:ok, underscore} = Inventory.list_catalog_items(%{"q" => "_"})
      assert underscore.items == []
    end

    test "an empty or whitespace search means no search" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      for blank <- ["", "   "] do
        assert {:ok, page} = Inventory.list_catalog_items(%{"q" => blank})
        assert Enum.map(page.items, & &1.id) == [item.id]
      end
    end
  end

  describe "filters" do
    test "filters by one or more categories" do
      %{category: swords, container_id: container_id} = fixture()
      masks = create_category!()

      {:ok, sword} = create_item(container_id, swords.id)
      {:ok, mask} = create_item(container_id, masks.id)

      assert {:ok, page} = Inventory.list_catalog_items(%{"categoryId" => swords.id})
      assert Enum.map(page.items, & &1.id) == [sword.id]

      assert {:ok, both} =
               Inventory.list_catalog_items(%{"categoryId" => "#{swords.id},#{masks.id}"})

      assert Enum.sort(Enum.map(both.items, & &1.id)) == Enum.sort([sword.id, mask.id])
    end

    test "ORs values of one definition and ANDs across definitions" do
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

      assert {:ok, either_size} =
               Inventory.list_catalog_items(%{
                 "property" => "#{size.id}:#{large.id},#{size.id}:#{small.id}"
               })

      assert Enum.sort(Enum.map(either_size.items, & &1.id)) ==
               Enum.sort([big_sharp.id, small_sharp.id, big_blunt.id])

      assert {:ok, sharp_only} =
               Inventory.list_catalog_items(%{
                 "property" => "#{size.id}:#{large.id},#{size.id}:#{small.id},#{sharp.id}:true"
               })

      assert Enum.sort(Enum.map(sharp_only.items, & &1.id)) ==
               Enum.sort([big_sharp.id, small_sharp.id])
    end

    test "rejects malformed filters instead of querying with them" do
      assert {:error, :invalid_category} =
               Inventory.list_catalog_items(%{"categoryId" => "not-a-uuid"})

      assert {:error, :invalid_property} =
               Inventory.list_catalog_items(%{"property" => "not-a-pair"})

      assert {:error, :invalid_limit} = Inventory.list_catalog_items(%{"limit" => "7"})
      assert {:error, :invalid_direction} = Inventory.list_catalog_items(%{"direction" => "up"})
    end
  end

  describe "pagination" do
    test "orders by the immutable slug and walks forward and back with exact counts" do
      %{category: category, container_id: container_id} = fixture()

      slugs =
        for _ <- 1..12 do
          {:ok, item} = create_item(container_id, category.id)
          item.slug
        end

      sorted = Enum.sort(slugs)

      assert {:ok, first} = Inventory.list_catalog_items(%{"limit" => "10"})
      assert Enum.map(first.items, & &1.slug) == Enum.take(sorted, 10)
      assert first.total_count == 12
      assert first.previous_cursor == nil
      assert is_binary(first.next_cursor)

      assert {:ok, second} =
               Inventory.list_catalog_items(%{"limit" => "10", "cursor" => first.next_cursor})

      assert Enum.map(second.items, & &1.slug) == Enum.drop(sorted, 10)
      assert second.total_count == 12
      assert second.next_cursor == nil

      assert {:ok, back} =
               Inventory.list_catalog_items(%{
                 "limit" => "10",
                 "cursor" => second.previous_cursor
               })

      assert Enum.map(back.items, & &1.slug) == Enum.take(sorted, 10)

      assert {:ok, descending} = Inventory.list_catalog_items(%{"direction" => "desc"})
      assert Enum.map(descending.items, & &1.slug) == Enum.sort(slugs, :desc)
    end

    test "a cursor from a different query is refused" do
      %{category: category, container_id: container_id} = fixture()
      other = create_category!()

      for _ <- 1..12, do: create_item(container_id, category.id)

      assert {:ok, page} = Inventory.list_catalog_items(%{"limit" => "10"})

      assert {:error, :bad_cursor} =
               Inventory.list_catalog_items(%{
                 "limit" => "10",
                 "cursor" => page.next_cursor,
                 "categoryId" => other.id
               })

      assert {:error, :bad_cursor} =
               Inventory.list_catalog_items(%{
                 "limit" => "10",
                 "cursor" => page.next_cursor,
                 "q" => "sword"
               })

      assert {:error, :bad_cursor} =
               Inventory.list_catalog_items(%{"limit" => "10", "cursor" => "not-a-cursor"})
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
        "name" => "Catalog category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Catalog container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "member-catalog-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  # Loan rows are fixtures for the catalog read; the loan commands are the
  # member request seam (`Dhc.Inventory.MemberLoans`) and ALE-286.
  defp create_loan!(item, borrower_id, status) do
    %{rows: [[loan_id]]} =
      Repo.query!(
        """
        INSERT INTO inventory_loans (
          item_id, borrower_principal_id, status,
          requested_start_on, requested_due_on,
          item_slug_snapshot, item_label_snapshot,
          created_at, updated_at
        )
        VALUES ($1, $2, $3, CURRENT_DATE, CURRENT_DATE + 7, $4, $5, NOW(), NOW())
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(item.id),
          Ecto.UUID.dump!(borrower_id),
          status,
          item.slug,
          item.label || item.slug
        ]
      )

    Ecto.UUID.load!(loan_id)
  end
end
