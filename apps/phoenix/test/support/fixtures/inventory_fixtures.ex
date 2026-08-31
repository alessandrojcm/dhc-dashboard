defmodule Dhc.InventoryFixtures do
  @moduledoc """
  Test helpers for creating raw Inventory rows (category, container, item).

  The category helper uses the schema changeset; the container and item
  helpers use raw SQL because their Supabase-era columns (e.g. `containers`
  FKs) predate the Phoenix schemas' full coverage.
  """

  alias Dhc.Auth.Principal
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Repo

  @doc """
  Inserts an Equipment Category via its schema changeset.
  """
  def insert_category(attrs) do
    attrs = Enum.into(attrs, %{})

    {:ok, category} =
      %EquipmentCategory{}
      |> Ecto.Changeset.cast(attrs, [:name, :description, :available_attributes])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  @doc """
  Inserts a Container (with a fresh Principal as `created_by`) and returns its id.

  Accepts an optional container name override.
  """
  def insert_container!(container_name \\ "Test Container") do
    user_id = Ecto.UUID.generate()

    %Principal{id: user_id}
    |> Principal.email_changeset(%{
      email: "inv-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()

    container_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        "INSERT INTO containers (id, name, created_by, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
        [Ecto.UUID.dump!(container_id), container_name, Ecto.UUID.dump!(user_id)]
      )

    container_id
  end

  @doc """
  Inserts an Inventory Item into the given container/category and returns
  `{:ok, item_id}`.
  """
  def insert_item(container_id, category_id) do
    item_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        """
        INSERT INTO inventory_items
          (id, container_id, category_id, attributes, quantity, created_at, updated_at)
        VALUES ($1, $2, $3, '{}'::jsonb, 1, NOW(), NOW())
        """,
        # All three are uuid columns — Postgrex requires 16-byte binaries, not
        # string UUIDs, for raw SQL parameters.
        [
          Ecto.UUID.dump!(item_id),
          Ecto.UUID.dump!(container_id),
          Ecto.UUID.dump!(category_id)
        ]
      )

    {:ok, item_id}
  end
end
