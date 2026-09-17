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
  alias Ecto.Adapters.SQL.Sandbox

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

    test "creating under a parent racing an archive of that parent never raises" do
      start_principal_tracker()

      parent =
        outside_sandbox(fn ->
          create_container!("Race parent #{System.unique_integer([:positive])}")
        end)

      on_exit(fn ->
        outside_sandbox(fn ->
          Repo.query!("DELETE FROM containers WHERE id = $1 OR parent_container_id = $1", [
            Ecto.UUID.dump!(parent.id)
          ])

          cleanup_principals()
        end)
      end)

      results =
        hold_lock_then(
          "SELECT id FROM containers WHERE id = $1 FOR UPDATE",
          [Ecto.UUID.dump!(parent.id)],
          [
            fn ->
              Inventory.create_container(
                %{
                  "name" => "Race child #{System.unique_integer([:positive])}",
                  "parentContainerId" => parent.id
                },
                principal_id()
              )
            end,
            fn -> Inventory.archive_container(parent.id) end
          ]
        )

      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:error, :active_dependants} -> true
               {:error, %Ecto.Changeset{}} -> true
               _other -> false
             end)

      outside_sandbox(fn ->
        {:ok, fresh} = Inventory.get_container(parent.id)
        children = fresh.child_containers || []

        if fresh.archived_at != nil do
          assert children == []
        end
      end)
    end
  end

  @principals_agent __MODULE__.CommittedPrincipals

  defp errors(changeset), do: changeset.errors

  defp hold_lock_then(sql, params, funs) do
    parent = self()
    holder = Task.async(fn -> hold_row_lock(sql, params, parent) end)

    assert_receive :locked, 5_000

    tasks = Enum.map(funs, fn fun -> Task.async(fn -> outside_sandbox(fun) end) end)

    try do
      :ok = outside_sandbox(fn -> wait_for_lock_waiter() end)

      Enum.each(tasks, fn task ->
        assert Task.yield(task, 200) == nil
      end)
    after
      send(holder.pid, :release)
    end

    assert {:ok, _} = Task.await(holder, 5_000)
    Enum.map(tasks, &Task.await(&1, :infinity))
  end

  defp hold_row_lock(sql, params, parent) do
    outside_sandbox(fn ->
      Repo.transaction(fn ->
        Repo.query!(sql, params)
        send(parent, :locked)
        receive do: (:release -> :ok)
      end)
    end)
  end

  defp wait_for_lock_waiter do
    Repo.query!(
      """
      DO $$
      DECLARE attempts int := 0;
      BEGIN
        LOOP
          EXIT WHEN EXISTS (
            SELECT 1
            FROM pg_locks blocked
            JOIN pg_stat_activity a ON a.pid = blocked.pid
            WHERE NOT blocked.granted
              AND blocked.pid <> pg_backend_pid()
          );
          attempts := attempts + 1;
          IF attempts > 500 THEN
            RAISE EXCEPTION 'no backend queued behind the held lock';
          END IF;
          PERFORM pg_sleep(0.01);
          PERFORM pg_stat_clear_snapshot();
        END LOOP;
      END
      $$
      """,
      []
    )

    :ok
  end

  defp start_principal_tracker do
    case Process.whereis(@principals_agent) do
      nil -> {:ok, _pid} = Agent.start_link(fn -> [] end, name: @principals_agent)
      _pid -> Agent.update(@principals_agent, fn _ids -> [] end)
    end
  end

  defp track_principal(id) do
    case Process.whereis(@principals_agent) do
      nil -> :ok
      _pid -> Agent.update(@principals_agent, &[id | &1])
    end
  end

  defp cleanup_principals do
    ids =
      case Process.whereis(@principals_agent) do
        nil -> []
        _pid -> Agent.get(@principals_agent, & &1)
      end

    if ids != [] do
      Repo.query!("DELETE FROM principals WHERE id = ANY($1::uuid[])", [ids])
    end
  end

  defp create_container!(name, parent_id \\ nil) do
    attrs = %{"name" => name}
    attrs = if parent_id, do: Map.put(attrs, "parentContainerId", parent_id), else: attrs
    assert {:ok, container} = Inventory.create_container(attrs, principal_id())
    container
  end

  defp principal_id do
    id =
      %Principal{id: Ecto.UUID.generate()}
      |> Principal.email_changeset(%{
        email: "container-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert!()
      |> Map.fetch!(:id)

    track_principal(id)
    id
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
        (id, container_id, category_id, slug, created_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(item_id),
        Ecto.UUID.dump!(container_id),
        Ecto.UUID.dump!(category_id),
        "test-#{System.unique_integer([:positive])}"
      ]
    )

    item_id
  end

  defp archive_item!(item_id) do
    Repo.query!("UPDATE inventory_items SET archived_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(item_id)
    ])
  end

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)
end
