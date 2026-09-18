defmodule Dhc.Inventory.ItemProjectionTest do
  @moduledoc """
  ALE-295: availability precedence is decided in one place.

  `availability/1` and the batched `project_all/1` path must agree:
  archived outranks maintenance, which outranks an active loan, which
  outranks available. A pending request is never an input.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Repo

  describe "availability precedence" do
    test "archived outranks an open maintenance period and an active loan" do
      %{item: %Item{} = item} = fixture()

      {:ok, _} =
        Inventory.start_operator_item_maintenance(
          item.id,
          %{"reason" => "Bent"},
          principal_id()
        )

      _loan_id = create_loan!(item, principal_id(), "approved")

      archived = %Item{item | archived_at: DateTime.utc_now()}

      assert ItemProjection.availability(archived) == %{
               available?: false,
               status: :archived
             }

      assert [%{availability: %{status: :archived}}] = ItemProjection.project_all([archived])
    end

    test "maintenance outranks an active loan, which outranks available" do
      %{item: available} = fixture()
      %{item: maintained} = fixture()
      %{item: on_loan} = fixture()

      {:ok, _} =
        Inventory.start_operator_item_maintenance(
          maintained.id,
          %{"reason" => "Bent"},
          principal_id()
        )

      _loan_id = create_loan!(on_loan, principal_id(), "approved")

      projected = ItemProjection.project_all([available, maintained, on_loan])
      statuses = Map.new(projected, &{&1.id, &1.availability})

      assert statuses[available.id] == %{available?: true, status: :available}
      assert statuses[maintained.id] == %{available?: false, status: :maintenance}
      assert statuses[on_loan.id] == %{available?: false, status: :on_loan}

      assert ItemProjection.availability(Repo.get!(Item, maintained.id)) ==
               statuses[maintained.id]

      assert ItemProjection.availability(Repo.get!(Item, on_loan.id)) ==
               statuses[on_loan.id]
    end

    test "a pending request never makes an item unavailable" do
      %{item: item} = fixture()
      _pending = create_loan!(item, principal_id(), "requested")

      assert ItemProjection.availability(item) == %{available?: true, status: :available}
      assert [%{availability: %{status: :available}}] = ItemProjection.project_all([item])
    end
  end

  defp fixture do
    category = create_category!()
    container = create_container!()

    {:ok, item} =
      Inventory.create_operator_item(
        %{"container_id" => container.id, "category_id" => category.id},
        principal_id()
      )

    %{item: item}
  end

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Projection category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Projection container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "item-projection-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

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
