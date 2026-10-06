defmodule Dhc.Inventory.OperatorLoansTest do
  @moduledoc """
  ALE-296 (ALE-286a): the operator loan read.

  Since GH-508 every operator loan transition is a facade over
  `Dhc.Inventory.AvailabilityCommands`, whose rules, concurrency, lock order,
  and database backstops are proven once in
  `Dhc.Inventory.AvailabilityCommandsTest`. Derived overdue is proven by
  `Dhc.Inventory.OperatorLoanQueueTest`. This file keeps the operator read
  the module itself owns.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.ClubCalendar
  alias Dhc.Repo

  describe "operator read" do
    test "discloses the borrower and the container path" do
      %{item: item} = fixture()
      member = principal_id()
      {:ok, request} = request(item, member)

      assert {:ok, view} = Inventory.get_operator_loan(request.id)
      assert view.borrower_principal_id == member
      assert view.item_slug == item.slug
      assert view.status == "requested"

      assert {:error, :not_found} = Inventory.get_operator_loan(Ecto.UUID.generate())
      assert {:error, :not_found} = Inventory.get_operator_loan("not-a-uuid")
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture do
    category = create_category!()
    container = create_container!()
    {:ok, item} = create_operator_item(container.id, category.id)

    %{category: category, container_id: container.id, item: item}
  end

  defp create_operator_item(container_id, category_id) do
    Inventory.create_operator_item(
      %{"container_id" => container_id, "category_id" => category_id},
      principal_id()
    )
  end

  defp request(item, borrower_id) do
    starts_on = ClubCalendar.today()
    due_on = Date.add(starts_on, 7)

    Inventory.request_loan(
      item.slug,
      %{"startsOn" => Date.to_iso8601(starts_on), "dueOn" => Date.to_iso8601(due_on)},
      borrower_id
    )
  end

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Operator loan category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Operator loan container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "operator-loans-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
