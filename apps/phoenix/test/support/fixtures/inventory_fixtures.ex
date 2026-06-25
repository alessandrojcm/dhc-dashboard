defmodule Dhc.InventoryFixtures do
  @moduledoc """
  Test helpers for creating Inventory persistence rows (Containers, Equipment
  Categories, Inventory Items) for the `Dhc.Inventory` read-model tests.

  Inserts go through the Ecto schemas in `Dhc.Inventory.*` so the fixture path
  exercises the same column mappings the read helpers query.

  Containers require a `created_by` auth user (NOT NULL FK to `auth.users`).
  Use `auth_user_fixture/0` to create one, or pass `:created_by` explicitly.
  """

  alias Dhc.Inventory.{Container, EquipmentCategory, InventoryItem}
  alias Dhc.Repo

  @doc """
  Inserts an `auth.users` row and returns its UUID string id.

  Needed because `containers.created_by` is a NOT NULL FK to
  `auth.users(id)` (Supabase-owned, no Ecto schema).
  """
  def auth_user_fixture do
    auth_user_id = Ecto.UUID.generate()

    Repo.insert_all(
      "users",
      [
        [
          id: Ecto.UUID.dump!(auth_user_id),
          aud: "authenticated",
          role: "authenticated",
          email: "inventory-#{System.unique_integer([:positive])}@example.com"
        ]
      ],
      prefix: "auth"
    )

    auth_user_id
  end

  @doc """
  Inserts a Container (a `containers` row).

  ## Options

    * `:name` (default `"Test Container"`)
    * `:description` (default `"A test container"`)
    * `:parent_container_id` (default `nil`)
    * `:created_by` (default: a fresh auth user)

  Returns the inserted `Container` struct.
  """
  def container_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    created_by = Map.get_lazy(attrs, :created_by, &auth_user_fixture/0)

    {:ok, container} =
      %Container{
        name: Map.get(attrs, :name, "Test Container"),
        description: Map.get(attrs, :description, "A test container"),
        parent_container_id: Map.get(attrs, :parent_container_id),
        created_by: created_by
      }
      |> Repo.insert()

    container
  end

  @doc """
  Inserts an Equipment Category (an `equipment_categories` row).

  ## Options

    * `:name` (default a unique generated name)
    * `:description` (default `"A test category"`)
    * `:available_attributes` (default `[]`; array of attribute definition maps)

  Returns the inserted `EquipmentCategory` struct.
  """
  def category_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {:ok, category} =
      %EquipmentCategory{
        name: Map.get(attrs, :name, "Category-#{System.unique_integer([:positive])}"),
        description: Map.get(attrs, :description, "A test category"),
        available_attributes: Map.get(attrs, :available_attributes, []),
        attribute_schema: Map.get(attrs, :attribute_schema, %{})
      }
      |> Repo.insert()

    category
  end

  @doc """
  Inserts an Inventory Item (an `inventory_items` row).

  Requires a `:container_id` and `:category_id` (the table has NOT NULL FKs).
  The default `out_for_maintenance` is `false`.

  ## Options

    * `:container_id` (required)
    * `:category_id` (required)
    * `:attributes` (default `%{}`; e.g. `%{"name" => "Longsword X"}`)
    * `:quantity` (default `1`)
    * `:out_for_maintenance` (default `false`)
    * `:notes` (default `nil`)
    * `:created_by` / `:updated_by` (default `nil`)

  Returns the inserted `InventoryItem` struct.
  """
  def item_fixture(attrs) do
    attrs = Enum.into(attrs, %{})

    {:ok, item} =
      %InventoryItem{
        container_id: Map.fetch!(attrs, :container_id),
        category_id: Map.fetch!(attrs, :category_id),
        attributes: Map.get(attrs, :attributes, %{}),
        quantity: Map.get(attrs, :quantity, 1),
        out_for_maintenance: Map.get(attrs, :out_for_maintenance, false),
        notes: Map.get(attrs, :notes),
        created_by: Map.get(attrs, :created_by),
        updated_by: Map.get(attrs, :updated_by)
      }
      |> Repo.insert()

    item
  end
end