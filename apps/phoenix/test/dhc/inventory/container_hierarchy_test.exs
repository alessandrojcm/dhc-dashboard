defmodule Dhc.Inventory.ContainerHierarchyTest do
  @moduledoc """
  ALE-291: inventory container hierarchy guards through the public
  `Dhc.Inventory` context seam.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.Container
  alias Dhc.Repo

  describe "container hierarchy" do
    test "enforces case-insensitive sibling names while allowing the same name elsewhere" do
      root = create_container!("Root")
      create_container!("Masks", root.id)

      assert {:error, changeset} =
               Inventory.create_container(
                 %{"name" => "masks", "parentContainerId" => root.id},
                 principal_id()
               )

      assert {"has already been taken", _} = changeset |> errors() |> Keyword.fetch!(:name)

      other_root = create_container!("Other root")

      assert {:ok, %Container{name: "MASKS"}} =
               Inventory.create_container(
                 %{"name" => "MASKS", "parentContainerId" => other_root.id},
                 principal_id()
               )
    end

    test "moves a whole subtree but rejects a self or descendant parent" do
      root = create_container!("Root")
      child = create_container!("Child", root.id)
      grandchild = create_container!("Grandchild", child.id)
      destination = create_container!("Destination")

      assert {:ok, %Container{parent_container_id: destination_id}} =
               Inventory.move_container(child.id, destination.id)

      assert destination_id == destination.id

      assert {:ok, %Container{parent_container_id: child_id}} =
               Inventory.get_container(grandchild.id)

      assert child_id == child.id

      assert {:error, :circular_parent} = Inventory.move_container(child.id, child.id)
      assert {:error, :circular_parent} = Inventory.move_container(destination.id, grandchild.id)
    end

    test "cannot move or create an active container beneath an archived parent" do
      archived_parent = create_container!("Archived parent")
      movable = create_container!("Movable")

      assert {:ok, _} = Inventory.archive_container(archived_parent.id)

      assert {:error, :archived_parent} = Inventory.move_container(movable.id, archived_parent.id)

      assert {:error, changeset} =
               Inventory.create_container(
                 %{"name" => "New child", "parentContainerId" => archived_parent.id},
                 principal_id()
               )

      assert {"must refer to an active container", _} =
               changeset |> errors() |> Keyword.fetch!(:parent_container_id)
    end

    test "archive requires every direct and descendant container and item to be handled explicitly" do
      parent = create_container!("Parent")
      child = create_container!("Child", parent.id)
      category = insert_category!()
      item_id = insert_item!(child.id, category.id)

      assert {:error, :active_dependants} = Inventory.archive_container(parent.id)
      assert {:error, :active_dependants} = Inventory.archive_container(child.id)

      archive_item!(item_id)
      assert {:ok, _} = Inventory.archive_container(child.id)
      assert {:ok, %Container{archived_at: archived_at}} = Inventory.archive_container(parent.id)
      assert archived_at != nil
    end

    test "restore requires an active parent chain" do
      parent = create_container!("Parent")
      child = create_container!("Child", parent.id)

      assert {:ok, _} = Inventory.archive_container(child.id)
      assert {:ok, _} = Inventory.archive_container(parent.id)

      assert {:error, :archived_parent} = Inventory.restore_container(child.id)
      assert {:ok, _} = Inventory.restore_container(parent.id)
      assert {:ok, %Container{archived_at: nil}} = Inventory.restore_container(child.id)
    end

    test "delete never recursively removes archived or active descendants or item references" do
      parent = create_container!("Parent")
      child = create_container!("Child", parent.id)

      assert {:ok, _} = Inventory.archive_container(child.id)
      assert {:error, :still_referenced} = Inventory.delete_container(parent.id)

      assert {:ok, _} = Inventory.delete_container(child.id)
      category = insert_category!()
      item_id = insert_item!(parent.id, category.id)
      archive_item!(item_id)

      assert {:error, :still_referenced} = Inventory.delete_container(parent.id)
    end
  end

  defp errors(changeset), do: changeset.errors

  defp create_container!(name, parent_id \\ nil) do
    attrs = %{"name" => name}
    attrs = if parent_id, do: Map.put(attrs, "parentContainerId", parent_id), else: attrs
    assert {:ok, container} = Inventory.create_container(attrs, principal_id())
    container
  end

  defp principal_id do
    id = Ecto.UUID.generate()

    %Principal{id: id}
    |> Principal.email_changeset(%{
      email: "container-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp insert_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Container category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp insert_item!(container_id, category_id) do
    item_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO inventory_items
        (id, container_id, category_id, attributes, quantity, created_at, updated_at)
      VALUES ($1, $2, $3, '{}'::jsonb, 1, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(container_id), Ecto.UUID.dump!(category_id)]
    )

    item_id
  end

  defp archive_item!(item_id) do
    Repo.query!("UPDATE inventory_items SET archived_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(item_id)
    ])
  end
end
