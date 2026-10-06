defmodule Dhc.Inventory.ContainerTreeTest do
  @moduledoc """
  ALE-346: `Dhc.Inventory.ContainerTree` is the only walker of the Container
  hierarchy — ancestors (read-only and share-locked), subtree walks, and
  path names.
  """

  use Dhc.DataCase, async: false

  import Dhc.ConcurrencyHelpers, only: [outside_sandbox: 1, wait_for_lock_waiter: 1]

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.ContainerTree
  alias Dhc.Repo

  describe "ancestors" do
    test "returns a deep chain root first, ending at the container" do
      actor = principal_id()
      chain = deep_chain!(actor, 6)
      leaf = List.last(chain)

      assert Enum.map(ContainerTree.ancestors(leaf.id), & &1.id) == Enum.map(chain, & &1.id)
      assert [%{id: root_id, archived_at: nil}] = ContainerTree.ancestors(hd(chain).id)
      assert root_id == hd(chain).id
    end

    test "a missing container has no ancestors" do
      assert ContainerTree.ancestors(Ecto.UUID.generate()) == []
      assert ContainerTree.lock_ancestors_for_share(Ecto.UUID.generate()) == {:error, :not_found}
      refute ContainerTree.chain_active?(Ecto.UUID.generate())
    end

    test "detects an archived ancestor anywhere up the chain" do
      actor = principal_id()
      [root, middle, leaf] = deep_chain!(actor, 3)

      assert ContainerTree.chain_active?(leaf.id)

      archive!(middle.id)

      refute ContainerTree.chain_active?(leaf.id)
      assert ContainerTree.chain_active?(root.id)

      assert {:ok, locked} = ContainerTree.lock_ancestors_for_share(leaf.id)
      assert Enum.map(locked, & &1.id) == [root.id, middle.id, leaf.id]
      assert [nil, %DateTime{}, nil] = Enum.map(locked, & &1.archived_at)
    end

    test "self_or_ancestor? answers whether a move would form a cycle" do
      actor = principal_id()
      [root, middle, leaf] = deep_chain!(actor, 3)
      other = create_container!(actor, "Other")

      assert ContainerTree.self_or_ancestor?(root.id, leaf.id)
      assert ContainerTree.self_or_ancestor?(middle.id, middle.id)
      refute ContainerTree.self_or_ancestor?(leaf.id, root.id)
      refute ContainerTree.self_or_ancestor?(other.id, leaf.id)
    end
  end

  describe "subtree" do
    test "active_dependants? sees descendant containers and items, not the container itself" do
      actor = principal_id()
      [root, middle, leaf] = deep_chain!(actor, 3)

      refute ContainerTree.active_dependants?(leaf.id)
      assert ContainerTree.active_dependants?(middle.id)

      archive!(leaf.id)
      refute ContainerTree.active_dependants?(middle.id)
      assert ContainerTree.active_dependants?(root.id)

      item_id = insert_item!(leaf.id)
      assert ContainerTree.active_dependants?(middle.id)
      assert ContainerTree.active_dependants?(leaf.id)

      Repo.query!("UPDATE inventory_items SET archived_at = NOW() WHERE id = $1", [
        Ecto.UUID.dump!(item_id)
      ])

      refute ContainerTree.active_dependants?(leaf.id)
    end

    test "lock_subtree_for_update locks every descendant container and item" do
      parent = self()

      {actor, chain, outsider, item_id} =
        outside_sandbox(fn ->
          actor = principal_id()
          chain = deep_chain!(actor, 3)
          {actor, chain, create_container!(actor, "Outsider"), insert_item!(List.last(chain).id)}
        end)

      on_exit(fn -> cleanup_committed!(actor, [outsider | Enum.reverse(chain)], [item_id]) end)

      holder =
        Task.async(fn ->
          outside_sandbox(fn ->
            Repo.transaction(fn ->
              :ok = ContainerTree.lock_subtree_for_update(hd(chain).id)
              send(parent, :locked)
              receive do: (:release -> :ok)
            end)
          end)
        end)

      assert_receive :locked, 5_000

      # A second connection skips exactly the rows the holder locked.
      unlocked = fn table, ids ->
        outside_sandbox(fn ->
          %{rows: rows} =
            Repo.query!(
              "SELECT id FROM #{table} WHERE id = ANY($1) FOR UPDATE SKIP LOCKED",
              [Enum.map(ids, &Ecto.UUID.dump!/1)]
            )

          Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
        end)
      end

      try do
        assert unlocked.("containers", [outsider.id | Enum.map(chain, & &1.id)]) == [outsider.id]
        assert unlocked.("inventory_items", [item_id]) == []
      after
        send(holder.pid, :release)
      end

      assert {:ok, :ok} = Task.await(holder, 5_000)
    end
  end

  describe "path_names/1" do
    test "renders root-first paths for several ids, including roots, skipping missing ids" do
      actor = principal_id()
      [root, middle, leaf] = deep_chain!(actor, 3)
      other_root = create_container!(actor, "Garage")
      missing = Ecto.UUID.generate()

      assert ContainerTree.path_names([leaf.id, middle.id, root.id, other_root.id, missing]) ==
               %{
                 leaf.id => "#{root.name} › #{middle.name} › #{leaf.name}",
                 middle.id => "#{root.name} › #{middle.name}",
                 root.id => root.name,
                 other_root.id => "Garage"
               }
    end

    test "an empty or unusable id list is an empty map" do
      assert ContainerTree.path_names([]) == %{}
      assert ContainerTree.path_names(["not-a-uuid", Ecto.UUID.generate()]) == %{}
    end
  end

  describe "share-locked ancestors (outside the sandbox)" do
    test "archiving a container blocks behind a held ancestor share lock" do
      parent = self()

      {actor, [root, middle, leaf]} =
        outside_sandbox(fn ->
          actor = principal_id()
          {actor, deep_chain!(actor, 3)}
        end)

      on_exit(fn -> cleanup_committed!(actor, [leaf, middle, root], []) end)

      holder =
        Task.async(fn ->
          outside_sandbox(fn ->
            Repo.transaction(fn ->
              {:ok, locked} = ContainerTree.lock_ancestors_for_share(leaf.id)
              send(parent, :locked)
              receive do: (:release -> :ok)
              locked
            end)
          end)
        end)

      assert_receive :locked, 5_000

      archiver =
        Task.async(fn -> outside_sandbox(fn -> Inventory.archive_container(leaf.id) end) end)

      try do
        :ok = outside_sandbox(fn -> wait_for_lock_waiter("%FOR UPDATE%") end)
        assert Task.yield(archiver, 200) == nil
      after
        send(holder.pid, :release)
      end

      assert {:ok, locked} = Task.await(holder, 5_000)
      assert Enum.map(locked, & &1.id) == [root.id, middle.id, leaf.id]
      assert Enum.all?(locked, &is_nil(&1.archived_at))

      assert {:ok, %{archived_at: %DateTime{}}} = Task.await(archiver, 5_000)
    end
  end

  # Children before parents, items before their containers.
  defp cleanup_committed!(actor, containers, item_ids) do
    outside_sandbox(fn ->
      for id <- item_ids do
        %{rows: [[category_id]]} =
          Repo.query!("DELETE FROM inventory_items WHERE id = $1 RETURNING category_id", [
            Ecto.UUID.dump!(id)
          ])

        Repo.query!("DELETE FROM equipment_categories WHERE id = $1", [category_id])
      end

      for container <- containers do
        Repo.query!("DELETE FROM containers WHERE id = $1", [Ecto.UUID.dump!(container.id)])
      end

      Repo.query!("DELETE FROM principals WHERE id = $1", [Ecto.UUID.dump!(actor)])
    end)
  end

  defp deep_chain!(actor, depth) do
    suffix = System.unique_integer([:positive])

    Enum.reduce(1..depth, [], fn level, acc ->
      parent_id =
        case acc do
          [] -> nil
          _ -> List.last(acc).id
        end

      acc ++ [create_container!(actor, "Level #{level} #{suffix}", parent_id)]
    end)
  end

  defp create_container!(actor, name, parent_id \\ nil) do
    attrs = %{"name" => name}
    attrs = if parent_id, do: Map.put(attrs, "parentContainerId", parent_id), else: attrs
    assert {:ok, container} = Inventory.create_container(attrs, actor)
    container
  end

  defp archive!(container_id) do
    Repo.query!("UPDATE containers SET archived_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(container_id)
    ])
  end

  defp insert_item!(container_id) do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Tree category #{System.unique_integer([:positive])}"
      })

    item_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO inventory_items (id, container_id, category_id, slug, created_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(item_id),
        Ecto.UUID.dump!(container_id),
        Ecto.UUID.dump!(category.id),
        "tree-#{System.unique_integer([:positive])}"
      ]
    )

    item_id
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "tree-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
