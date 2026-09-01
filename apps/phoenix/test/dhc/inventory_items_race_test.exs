defmodule Dhc.InventoryItemsRaceTest do
  use Dhc.DataCase, async: false

  import Ecto.Query

  alias Dhc.Inventory
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.InventoryHistory
  alias Dhc.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "an update that loses the read/write race returns the current item" do
    fixture = unboxed(&insert_item!/0)
    {item, actor_id} = fixture

    on_exit(fn -> unboxed(fn -> delete_item_fixture!(fixture) end) end)

    assert {:error, {:version_precondition_failed, current}} =
             race_item_write(item, fn ->
               Inventory.update_item(item.id, %{"quantity" => 3}, actor_id,
                 expected_lock_version: 1
               )
             end)

    assert current.id == item.id
    assert current.quantity == 2
    assert current.lock_version == 2
  end

  test "a delete that loses the read/write race returns the current item" do
    fixture = unboxed(&insert_item!/0)
    {item, _actor_id} = fixture

    on_exit(fn -> unboxed(fn -> delete_item_fixture!(fixture) end) end)

    assert {:error, {:version_precondition_failed, current}} =
             race_item_write(item, fn ->
               Inventory.delete_item(item.id, expected_lock_version: 1)
             end)

    assert current.id == item.id
    assert current.quantity == 2
    assert current.lock_version == 2
  end

  test "a move that loses the read/write race returns the current item" do
    fixture = unboxed(&insert_item!/0)
    {item, actor_id} = fixture
    destination_id = unboxed(fn -> insert_container!(actor_id, "Race destination") end)

    on_exit(fn ->
      unboxed(fn -> delete_item_fixture!(fixture, [destination_id]) end)
    end)

    assert {:error, {:version_precondition_failed, current}} =
             race_item_write(item, fn ->
               Inventory.move_item(
                 item.id,
                 %{"containerId" => destination_id},
                 actor_id,
                 expected_lock_version: 1
               )
             end)

    assert current.id == item.id
    assert current.quantity == 2
    assert current.lock_version == 2
  end

  test "a maintenance update that loses the read/write race returns the current item" do
    fixture = unboxed(&insert_item!/0)
    {item, actor_id} = fixture

    on_exit(fn -> unboxed(fn -> delete_item_fixture!(fixture) end) end)

    assert {:error, {:version_precondition_failed, current}} =
             race_item_write(item, fn ->
               Inventory.set_item_maintenance(
                 item.id,
                 %{"outForMaintenance" => true},
                 actor_id,
                 expected_lock_version: 1
               )
             end)

    assert current.id == item.id
    assert current.quantity == 2
    assert current.lock_version == 2
  end

  test "a delete that loses the race to a vanished item returns not found" do
    fixture = unboxed(&insert_item!/0)
    {item, _actor_id} = fixture

    on_exit(fn -> unboxed(fn -> delete_item_fixture!(fixture) end) end)

    assert {:error, :not_found} =
             race_item_write(
               item,
               fn -> Inventory.delete_item(item.id, expected_lock_version: 1) end,
               &Repo.delete!/1
             )
  end

  defp race_item_write(item, write_fun, locked_write_fun \\ &bump_item_version/1) do
    test_process = self()
    task_supervisor = start_supervised!(Task.Supervisor)

    locker = lock_item(task_supervisor, item, test_process, locked_write_fun)

    assert_receive :item_locked

    writer =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(test_process, {:writer_backend, backend_pid})
          write_fun.()
        end)
      end)

    assert_receive {:writer_backend, writer_backend}
    assert_backend_waiting_on_lock(writer_backend)

    send(locker.pid, :bump_item_version)
    assert {:ok, _} = Task.await(locker)

    Task.await(writer)
  end

  defp bump_item_version(item) do
    item
    |> Ecto.Changeset.change(quantity: 2)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update!()
  end

  defp lock_item(task_supervisor, item, test_process, locked_write_fun) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      lock_item_transaction(item.id, test_process, locked_write_fun)
    end)
  end

  defp lock_item_transaction(item_id, test_process, locked_write_fun) do
    unboxed(fn ->
      Repo.transaction(fn ->
        locked_item = fetch_item_for_update!(item_id)
        send(test_process, :item_locked)
        apply_locked_write(locked_item, locked_write_fun)
      end)
    end)
  end

  defp fetch_item_for_update!(item_id) do
    Repo.one!(
      from(item_row in Item,
        where: item_row.id == ^item_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp apply_locked_write(locked_item, locked_write_fun) do
    receive do
      :bump_item_version -> locked_write_fun.(locked_item)
    end
  end

  defp assert_backend_waiting_on_lock(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_assert_backend_waiting_on_lock(backend_pid, deadline)
  end

  defp do_assert_backend_waiting_on_lock(backend_pid, deadline) do
    waiting? =
      unboxed(fn ->
        case Repo.query!(
               "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
               [backend_pid]
             ).rows do
          [["Lock"]] -> true
          _rows -> false
        end
      end)

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        do_assert_backend_waiting_on_lock(backend_pid, deadline)

      true ->
        flunk("database backend #{backend_pid} did not wait on the item row lock")
    end
  end

  defp insert_item! do
    actor_id = Ecto.UUID.generate()
    container_id = Ecto.UUID.generate()

    {:ok, _principal} =
      Dhc.Auth.register_principal_with_id(actor_id, %{
        email: "inventory-race-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, category} =
      %EquipmentCategory{}
      |> Ecto.Changeset.cast(%{name: "Inventory Race #{System.unique_integer([:positive])}"}, [
        :name
      ])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    Repo.query!(
      """
      INSERT INTO containers (id, name, created_by, created_at, updated_at)
      VALUES ($1, $2, $3, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(container_id),
        "Inventory race container",
        Ecto.UUID.dump!(actor_id)
      ]
    )

    item =
      Repo.insert!(%Item{
        container_id: container_id,
        category_id: category.id,
        attributes: %{},
        quantity: 1,
        created_by: actor_id
      })

    {item, actor_id}
  end

  defp insert_container!(actor_id, name) do
    container_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO containers (id, name, created_by, created_at, updated_at)
      VALUES ($1, $2, $3, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(container_id), name, Ecto.UUID.dump!(actor_id)]
    )

    container_id
  end

  defp delete_item_fixture!({item, actor_id}, extra_container_ids \\ []) do
    Repo.delete_all(from(history in InventoryHistory, where: history.item_id == ^item.id))
    Repo.delete_all(from(item_row in Item, where: item_row.id == ^item.id))
    Repo.query!("DELETE FROM containers WHERE id = $1", [Ecto.UUID.dump!(item.container_id)])

    Enum.each(extra_container_ids, fn container_id ->
      Repo.query!("DELETE FROM containers WHERE id = $1", [Ecto.UUID.dump!(container_id)])
    end)

    Repo.delete_all(from(category in EquipmentCategory, where: category.id == ^item.category_id))
    Repo.delete_all(from(principal in Dhc.Auth.Principal, where: principal.id == ^actor_id))
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
