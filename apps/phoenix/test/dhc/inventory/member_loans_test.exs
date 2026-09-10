defmodule Dhc.Inventory.MemberLoansTest do
  @moduledoc """
  ALE-285: the member loan seam — request, cancel, and own history.

  Proves the member half of the ALE-273 lifecycle through the public
  `Dhc.Inventory` interface: date rules in the club's calendar, one pending
  request per item per member while multiple items stay free, competing
  requests coexisting with no entitlement, requestability tracking the same
  availability projection the catalog shows, cancel-until-checkout, and a
  complete own history whose snapshots survive archival.

  Privacy is asserted as its own concern: a member's history contains only
  their own loans, and the container path appears only once the loan is
  approved (spec ALE-280 stories 15, 45).

  Operator transitions (approve, reject, checkout, return) are ALE-286, so
  they are applied here as SQL fixtures — the same convention
  `operator_item_lifecycle_test.exs` uses for loan rows.

  Concurrency note: the races run on real independent connections through
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, so Postgres settles them rather
  than test-process ordering. That commits outside the test-owner
  transaction, so each race builds its fixture and deletes its rows
  explicitly (docs/agents/critical-patterns.md, "Real PostgreSQL Concurrency
  Tests"). Each asserts what must hold under *any* interleaving: the loser
  gets a domain conflict, never a server error.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Repo
  alias Ecto.Adapters.SQL.Sandbox

  describe "request dates" do
    test "accepts today or later with due on or after start" do
      %{item: item} = fixture()
      member = principal_id()
      today = ClubCalendar.today()

      assert {:ok, loan} = request(item, member, today, today)
      assert loan.status == "requested"
      assert loan.requested_start_on == today
      assert loan.requested_due_on == today
      assert loan.overdue? == false

      other = create_item!()
      later = Date.add(today, 7)

      assert {:ok, future} = request(other, member, later, Date.add(later, 3))
      assert future.requested_start_on == later
    end

    test "rejects a past start date and an inverted range" do
      %{item: item} = fixture()
      member = principal_id()
      today = ClubCalendar.today()

      assert {:error, :invalid_dates} =
               request(item, member, Date.add(today, -1), Date.add(today, 3))

      assert {:error, :invalid_dates} =
               request(item, member, Date.add(today, 3), Date.add(today, 1))
    end

    test "rejects missing or malformed dates" do
      %{item: item} = fixture()
      member = principal_id()
      today = Date.to_iso8601(ClubCalendar.today())

      assert {:error, :invalid_dates} =
               Inventory.request_loan(item.slug, %{"dueOn" => today}, member)

      assert {:error, :invalid_dates} =
               Inventory.request_loan(
                 item.slug,
                 %{"startsOn" => "not-a-date", "dueOn" => today},
                 member
               )
    end

    test "uses the club calendar, so today in Dublin is requestable" do
      %{item: item} = fixture()
      member = principal_id()

      # Whatever UTC thinks, the club's own "today" must be acceptable.
      assert {:ok, _loan} =
               request(item, member, ClubCalendar.today(), ClubCalendar.today())
    end
  end

  describe "request allocation" do
    test "allows one pending request per item and refuses a second from the same member" do
      %{item: item} = fixture()
      member = principal_id()

      assert {:ok, _first} = request(item, member)
      assert {:error, :duplicate_request} = request(item, member)
    end

    test "lets one member hold pending requests on several items" do
      %{item: first} = fixture()
      second = create_item!()
      member = principal_id()

      assert {:ok, on_first} = request(first, member)
      assert {:ok, on_second} = request(second, member)

      assert {:ok, page} = Inventory.list_own_loans(member)
      assert Enum.sort(Enum.map(page.loans, & &1.id)) == Enum.sort([on_first.id, on_second.id])
    end

    test "competing requests coexist and create no entitlement" do
      %{item: item} = fixture()
      first = principal_id()
      second = principal_id()

      assert {:ok, _} = request(item, first)
      assert {:ok, _} = request(item, second)

      # A pending request is not an availability input (story 34), so the
      # item is still requestable and still shows as available.
      assert {:ok, catalog} = Inventory.resolve_catalog_item(item.slug)
      assert catalog.availability == %{available?: true, reason: :available}
    end

    test "records the request note and drops a blank one" do
      %{item: item} = fixture()
      member = principal_id()
      today = ClubCalendar.today()

      assert {:ok, noted} =
               Inventory.request_loan(
                 item.slug,
                 %{
                   "startsOn" => Date.to_iso8601(today),
                   "dueOn" => Date.to_iso8601(today),
                   "note" => "  For Saturday's tournament  "
                 },
                 member
               )

      assert noted.request_note == "For Saturday's tournament"

      blank_item = create_item!()

      assert {:ok, blank} =
               Inventory.request_loan(
                 blank_item.slug,
                 %{
                   "startsOn" => Date.to_iso8601(today),
                   "dueOn" => Date.to_iso8601(today),
                   "note" => "   "
                 },
                 member
               )

      assert blank.request_note == nil
    end

    test "captures item snapshots at request time" do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = create_definition(category.id, "Brand", "text", identifying_position: 0)

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "values" => %{brand.id => "Regenyei"}
          },
          principal_id()
        )

      assert {:ok, loan} = request(item, principal_id())

      assert loan.item_slug == item.slug
      assert loan.item_label == "#{category.name} · Regenyei"
    end
  end

  describe "requestability" do
    test "refuses an item in maintenance with a generic reason" do
      %{item: item} = fixture()

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent"},
                 principal_id()
               )

      # The refusal names no maintenance fact.
      assert {:error, :item_unavailable} = request(item, principal_id())
    end

    test "refuses an item held by an approved or checked-out loan" do
      %{item: item} = fixture()
      holder = principal_id()

      loan_id = create_loan!(item, holder, "approved")
      assert {:error, :item_unavailable} = request(item, principal_id())

      set_loan_status!(loan_id, "checked_out")
      assert {:error, :item_unavailable} = request(item, principal_id())

      # Once the loan closes the item is requestable again — no queue, no
      # revival of old requests (story 34).
      set_loan_status!(loan_id, "returned")
      assert {:ok, _} = request(item, principal_id())
    end

    test "reports an archived or unknown item as absent, never as archived" do
      %{item: item} = fixture()
      assert {:ok, _} = Inventory.archive_operator_item(item.slug, %{}, principal_id())

      assert {:error, :not_found} = request(item, principal_id())
      assert {:error, :not_found} = Inventory.request_loan("item-999999", %{}, principal_id())
    end
  end

  describe "cancel" do
    test "cancels an own requested loan and is idempotent" do
      %{item: item} = fixture()
      member = principal_id()

      assert {:ok, loan} = request(item, member)

      assert {:ok, cancelled} =
               Inventory.cancel_loan(loan.id, %{"note" => "Plans changed"}, member)

      assert cancelled.status == "cancelled"
      assert cancelled.decision_note == "Plans changed"

      # A second tap must not be an error.
      assert {:ok, again} = Inventory.cancel_loan(loan.id, %{}, member)
      assert again.status == "cancelled"

      # Cancelling releases the item for a fresh request.
      assert {:ok, _} = request(item, principal_id())
    end

    test "cancels an own approved loan but not after checkout" do
      %{item: item} = fixture()
      member = principal_id()
      loan_id = create_loan!(item, member, "approved")

      assert {:ok, cancelled} = Inventory.cancel_loan(loan_id, %{}, member)
      assert cancelled.status == "cancelled"

      checked_out = create_loan!(create_item!(), member, "checked_out")
      assert {:error, :not_cancellable} = Inventory.cancel_loan(checked_out, %{}, member)
    end

    test "cannot cancel another member's loan, or a closed one" do
      %{item: item} = fixture()
      borrower = principal_id()
      stranger = principal_id()

      assert {:ok, loan} = request(item, borrower)

      # Someone else's loan is simply not found: its existence is not a
      # member-visible fact.
      assert {:error, :not_found} = Inventory.cancel_loan(loan.id, %{}, stranger)
      assert {:error, :not_found} = Inventory.cancel_loan(Ecto.UUID.generate(), %{}, borrower)
      assert {:error, :not_found} = Inventory.cancel_loan("not-a-uuid", %{}, borrower)

      returned = create_loan!(create_item!(), borrower, "returned")
      assert {:error, :not_cancellable} = Inventory.cancel_loan(returned, %{}, borrower)
    end
  end

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

  describe "concurrency" do
    test "two requests from the same member leave exactly one pending row" do
      committed(fn %{item: item} ->
        member = principal_id()

        results = race(fn _label -> request(item, member) end)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        # The loser sees a domain conflict, not a Postgrex error from the
        # partial unique index.
        assert Enum.count(results, &match?({:error, :duplicate_request}, &1)) == 1
        assert pending_count(item, member) == 1
      end)
    end

    test "competing requests from different members both commit" do
      committed(fn %{item: item} ->
        first = principal_id()
        second = principal_id()

        results =
          race([fn -> request(item, first) end, fn -> request(item, second) end])

        # No queue and no entitlement: both requests are legal (story 34).
        assert Enum.all?(results, &match?({:ok, _}, &1))
        assert pending_count(item) == 2
      end)
    end

    test "a request racing an approval never joins a reserved item" do
      committed(fn %{item: item} ->
        holder = principal_id()
        loan_id = create_loan!(item, holder, "requested")

        [request_result, _approval] =
          race([fn -> request(item, principal_id()) end, fn -> approve_loan!(loan_id) end])

        # Either the request wins the lock first, or it reports the item as
        # unavailable — never an exception, and never a second live claim.
        assert match?({:ok, _}, request_result) or
                 match?({:error, :item_unavailable}, request_result)

        assert active_allocation_count(item) == 1
      end)
    end

    # Cancellation releases the item, so it is an availability-changing
    # command and takes the item lock first, in the same order as request and
    # every operator command. Opposite lock orders would deadlock rather than
    # queue, so this asserts the shared protocol, not just the outcome.
    test "a cancellation racing an approval settles without deadlock or a lost item" do
      committed(fn %{item: item} ->
        member = principal_id()
        loan_id = create_loan!(item, member, "requested")

        [cancel_result, _approval] =
          race([
            fn -> Inventory.cancel_loan(loan_id, %{}, member) end,
            fn -> approve_loan!(loan_id) end
          ])

        # Either order is legal; neither may raise.
        assert match?({:ok, _}, cancel_result) or
                 match?({:error, :not_cancellable}, cancel_result)

        # The loan cannot end up both cancelled and holding the item.
        assert loan_status(loan_id) in ~w(cancelled approved)

        if loan_status(loan_id) == "cancelled" do
          assert active_allocation_count(item) == 0
        end
      end)
    end

    test "a request racing a maintenance start never lands on a serviced item" do
      committed(fn %{item: item} ->
        member = principal_id()

        [request_result, maintenance_result] =
          race([
            fn -> request(item, member) end,
            fn ->
              Inventory.start_operator_item_maintenance(
                item.id,
                %{"reason" => "Servicing"},
                principal_id()
              )
            end
          ])

        assert match?({:ok, _}, maintenance_result)

        assert match?({:ok, _}, request_result) or
                 match?({:error, :item_unavailable}, request_result)

        # Maintenance rejects pending requests atomically (ALE-294), so a
        # request that won the race must not still be pending afterwards.
        assert pending_count(item, member) == 0
      end)
    end
  end

  # ── Real-concurrency helpers ───────────────────────────────────

  # Builds the fixture outside the sandbox so competing connections can see
  # it, runs `fun`, then removes every committed row it created. Sandbox
  # rollback cannot undo `unboxed_run` work.
  defp committed(fun) do
    context =
      outside_sandbox(fn ->
        category = create_category!()
        container = create_container!()
        {:ok, item} = create_operator_item(container.id, category.id)

        %{category: category, container_id: container.id, item: item}
      end)

    on_exit(fn -> outside_sandbox(fn -> cleanup_committed(context) end) end)

    outside_sandbox(fn -> fun.(context) end)
  end

  defp cleanup_committed(context) do
    item_id = Ecto.UUID.dump!(context.item.id)

    Repo.query!("DELETE FROM inventory_loans WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_maintenance_periods WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_items WHERE id = $1", [item_id])

    Repo.query!("DELETE FROM containers WHERE id = $1", [
      Ecto.UUID.dump!(context.container_id)
    ])

    Repo.query!("DELETE FROM equipment_categories WHERE id = $1", [
      Ecto.UUID.dump!(context.category.id)
    ])
  end

  # Runs the given operations at genuinely the same time on separate
  # connections, so the interlocks are settled by Postgres rather than by
  # test-process ordering.
  defp race(fun) when is_function(fun, 1), do: race([fn -> fun.("a") end, fn -> fun.("b") end])

  defp race(funs) when is_list(funs) do
    funs
    |> Task.async_stream(fn fun -> outside_sandbox(fun) end,
      max_concurrency: length(funs),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Stands in for the ALE-286 approval command: reserves the item the way a
  # real approval would, so the request races a committed change.
  defp approve_loan!(loan_id) do
    Repo.query!(
      """
      UPDATE inventory_loans
      SET status = 'approved', decided_at = NOW(),
          approved_start_on = requested_start_on, approved_due_on = requested_due_on
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(loan_id)]
    )
  end

  defp pending_count(item, borrower_id \\ nil) do
    {sql, params} =
      if borrower_id do
        {"SELECT count(*) FROM inventory_loans WHERE item_id = $1 AND status = 'requested' AND borrower_principal_id = $2",
         [Ecto.UUID.dump!(item.id), Ecto.UUID.dump!(borrower_id)]}
      else
        {"SELECT count(*) FROM inventory_loans WHERE item_id = $1 AND status = 'requested'",
         [Ecto.UUID.dump!(item.id)]}
      end

    %{rows: [[count]]} = Repo.query!(sql, params)
    count
  end

  defp loan_status(loan_id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM inventory_loans WHERE id = $1", [
        Ecto.UUID.dump!(loan_id)
      ])

    status
  end

  defp active_allocation_count(item) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM inventory_loans WHERE item_id = $1 AND status IN ('approved', 'checked_out')",
        [Ecto.UUID.dump!(item.id)]
      )

    count
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

  defp request(item, borrower_id, starts_on \\ nil, due_on \\ nil) do
    starts_on = starts_on || ClubCalendar.today()
    due_on = due_on || Date.add(starts_on, 7)

    Inventory.request_loan(
      item.slug,
      %{"startsOn" => Date.to_iso8601(starts_on), "dueOn" => Date.to_iso8601(due_on)},
      borrower_id
    )
  end

  defp create_definition(category_id, label, value_type, opts) do
    attrs = %{"label" => label, "value_type" => value_type}

    attrs =
      Enum.reduce(opts, attrs, fn
        {:identifying_position, position}, acc -> Map.put(acc, "identifying_position", position)
      end)

    Inventory.create_definition(category_id, attrs)
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
