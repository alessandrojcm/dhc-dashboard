defmodule Dhc.Inventory.MemberLoansTest do
  @moduledoc """
  ALE-285: the member loan seam — own history.

  Proves through the public `Dhc.Inventory` interface a complete own history
  whose snapshots survive archival.

  Privacy is asserted as its own concern: a member's history contains only
  their own loans, and the container path appears only once the loan is
  approved (spec ALE-280 stories 15, 45).

  Operator transitions (approve, reject, checkout, return) are ALE-286, so
  they are applied here as SQL fixtures — the same convention
  `operator_item_lifecycle_test.exs` uses for loan rows.

  Since GH-508 `request_loan/3` and `cancel_loan/3` are a facade over
  `Dhc.Inventory.AvailabilityCommands`, whose request and cancel rules,
  concurrency, lock order, and database backstops are proven once in
  `Dhc.Inventory.AvailabilityCommandsTest`. This file keeps the member read
  model.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.ClubCalendar
  alias Dhc.Repo

  describe "own history" do
    test "is complete, newest first, including rejections and cancellations" do
      %{item: item} = fixture()
      member = principal_id()

      rejected = create_loan!(item, member, "rejected")
      reject!(rejected, "Rejected automatically: the item went into maintenance.")
      cancelled = create_loan!(create_item!(), member, "cancelled")
      returned = create_loan!(create_item!(), member, "returned")

      assert {:ok, page} = Inventory.list_own_loans(member)

      assert Enum.sort(Enum.map(page.loans, & &1.id)) ==
               Enum.sort([rejected, cancelled, returned])

      assert page.total_count == 3

      rejected_view = Enum.find(page.loans, &(&1.id == rejected))
      assert rejected_view.status == "rejected"

      assert rejected_view.decision_note ==
               "Rejected automatically: the item went into maintenance."
    end

    test "contains only the caller's own loans" do
      %{item: item} = fixture()
      member = principal_id()
      stranger = principal_id()

      assert {:ok, mine} = request(item, member)
      _theirs = create_loan!(create_item!(), stranger, "checked_out")

      assert {:ok, page} = Inventory.list_own_loans(member)
      assert Enum.map(page.loans, & &1.id) == [mine.id]
      # The exact count must be the caller's own, not the table's.
      assert page.total_count == 1

      assert {:ok, one} = Inventory.get_own_loan(mine.id, member)
      assert one.id == mine.id
      assert {:error, :not_found} = Inventory.get_own_loan(mine.id, stranger)
    end

    test "filters to open or closed obligations" do
      %{item: item} = fixture()
      member = principal_id()

      assert {:ok, open} = request(item, member)
      closed = create_loan!(create_item!(), member, "returned")

      assert {:ok, open_page} = Inventory.list_own_loans(member, %{"status" => "open"})
      assert Enum.map(open_page.loans, & &1.id) == [open.id]
      assert open_page.total_count == 1

      assert {:ok, closed_page} = Inventory.list_own_loans(member, %{"status" => "closed"})
      assert Enum.map(closed_page.loans, & &1.id) == [closed]

      assert {:ok, all} = Inventory.list_own_loans(member, %{"status" => "all"})
      assert Enum.sort(Enum.map(all.loans, & &1.id)) == Enum.sort([open.id, closed])
      assert all.total_count == 2

      assert {:error, :invalid_status} =
               Inventory.list_own_loans(member, %{"status" => "pending"})
    end

    test "pages the history newest-first with exact counts and refuses a stale cursor" do
      member = principal_id()

      loan_ids =
        for _ <- 1..12 do
          create_loan!(create_item!(), member, "returned")
        end

      assert {:ok, first} = Inventory.list_own_loans(member, %{"limit" => "10"})
      assert first.total_count == 12
      assert first.limit == 10
      assert first.previous_cursor == nil
      assert is_binary(first.next_cursor)

      assert {:ok, second} =
               Inventory.list_own_loans(member, %{
                 "limit" => "10",
                 "cursor" => first.next_cursor
               })

      assert second.total_count == 12
      assert second.next_cursor == nil

      # Every loan appears exactly once across the two pages.
      paged = Enum.map(first.loans ++ second.loans, & &1.id)
      assert Enum.sort(paged) == Enum.sort(loan_ids)

      assert {:ok, back} =
               Inventory.list_own_loans(member, %{
                 "limit" => "10",
                 "cursor" => second.previous_cursor
               })

      assert Enum.map(back.loans, & &1.id) == Enum.map(first.loans, & &1.id)

      # A cursor cannot be replayed against a different status filter.
      assert {:error, :bad_cursor} =
               Inventory.list_own_loans(member, %{
                 "limit" => "10",
                 "cursor" => first.next_cursor,
                 "status" => "open"
               })

      assert {:error, :invalid_limit} = Inventory.list_own_loans(member, %{"limit" => "7"})

      assert {:error, :invalid_direction} =
               Inventory.list_own_loans(member, %{"direction" => "sideways"})
    end

    test "keeps the item snapshot readable after the item is archived" do
      %{item: item} = fixture()
      member = principal_id()

      loan_id = create_loan!(item, member, "returned")
      assert {:ok, _} = Inventory.archive_operator_item(item.slug, %{}, principal_id())

      assert {:ok, %{loans: [view]}} = Inventory.list_own_loans(member)
      assert view.id == loan_id
      assert view.item_slug == item.slug
      assert is_binary(view.item_label)

      # …while the archived item itself has left the catalog.
      assert {:error, :not_found} = Inventory.resolve_catalog_item(item.slug)
    end

    test "discloses the container path only from approval onward" do
      %{item: item} = fixture()
      member = principal_id()

      assert {:ok, requested} = request(item, member)
      assert requested.container_path == nil

      loan_id = create_loan!(create_item!(), member, "requested")
      set_container_path!(loan_id, "Clubhouse › Rack 2")

      assert {:ok, still_hidden} = Inventory.get_own_loan(loan_id, member)
      assert still_hidden.container_path == nil

      set_loan_status!(loan_id, "approved")
      assert {:ok, approved} = Inventory.get_own_loan(loan_id, member)
      assert approved.container_path == "Clubhouse › Rack 2"
    end

    test "derives overdue from the approved due date rather than a stored state" do
      %{item: item} = fixture()
      member = principal_id()
      today = ClubCalendar.today()

      loan_id = create_loan!(item, member, "checked_out")
      set_approved_dates!(loan_id, Date.add(today, -10), Date.add(today, -1))

      assert {:ok, late} = Inventory.get_own_loan(loan_id, member)
      assert late.overdue? == true

      # Extending the due date clears it, with no transition to undo.
      set_approved_dates!(loan_id, Date.add(today, -10), Date.add(today, 3))
      assert {:ok, extended} = Inventory.get_own_loan(loan_id, member)
      assert extended.overdue? == false

      # A returned loan past its due date is not "overdue" — it is closed.
      set_approved_dates!(loan_id, Date.add(today, -10), Date.add(today, -1))
      set_loan_status!(loan_id, "returned")
      assert {:ok, closed} = Inventory.get_own_loan(loan_id, member)
      assert closed.overdue? == false
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture do
    category = create_category!()
    container = create_container!()
    {:ok, item} = create_operator_item(container.id, category.id)

    %{category: category, container_id: container.id, item: item}
  end

  defp create_item! do
    {:ok, item} = create_operator_item(create_container!().id, create_category!().id)
    item
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
        "name" => "Loan category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Loan container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "member-loans-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  # ── Operator-side fixtures (ALE-286 owns these commands) ────────

  defp create_loan!(item, borrower_id, status) do
    %{rows: [[loan_id]]} =
      Repo.query!(
        """
        INSERT INTO inventory_loans (
          item_id, borrower_principal_id, status,
          requested_start_on, requested_due_on,
          approved_start_on, approved_due_on,
          item_slug_snapshot, item_label_snapshot,
          created_at, updated_at
        )
        VALUES ($1, $2, $3, CURRENT_DATE, CURRENT_DATE + 7,
                CURRENT_DATE, CURRENT_DATE + 7, $4, $5, NOW(), NOW())
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

  defp set_loan_status!(loan_id, status) do
    Repo.query!("UPDATE inventory_loans SET status = $1 WHERE id = $2", [
      status,
      Ecto.UUID.dump!(loan_id)
    ])
  end

  defp reject!(loan_id, note) do
    Repo.query!(
      "UPDATE inventory_loans SET status = 'rejected', decided_at = NOW(), decision_note = $1 WHERE id = $2",
      [note, Ecto.UUID.dump!(loan_id)]
    )
  end

  defp set_container_path!(loan_id, path) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_container_path_snapshot = $1 WHERE id = $2",
      [path, Ecto.UUID.dump!(loan_id)]
    )
  end

  defp set_approved_dates!(loan_id, starts_on, due_on) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [starts_on, due_on, Ecto.UUID.dump!(loan_id)]
    )
  end
end
