defmodule Dhc.Inventory.LoanProjectionTest do
  @moduledoc """
  ALE-358: the member view's advisory `cancellable?` is the member-cancel
  predicate from `Dhc.Inventory.LoanPolicy`, so the button a member sees can be
  stale but never computed by a different rule than the cancel command.
  """

  use ExUnit.Case, async: true

  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.LoanPolicy
  alias Dhc.Inventory.LoanProjection

  @today ~D[2026-10-06]

  defp loan(status) do
    %Loan{
      id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
      item_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      status: status,
      requested_start_on: @today,
      requested_due_on: Date.add(@today, 7),
      item_slug_snapshot: "item-000042",
      item_label_snapshot: "Regenyei Feder"
    }
  end

  describe "LoanPolicy.member_cancellable?/1" do
    test "only a requested or approved loan can still be cancelled by its member" do
      assert LoanPolicy.member_cancellable?(loan("requested"))
      assert LoanPolicy.member_cancellable?(loan("approved"))

      for status <- ~w(rejected cancelled checked_out returned) do
        refute LoanPolicy.member_cancellable?(loan(status)), status
      end
    end
  end

  describe "member_view/2 cancellable?" do
    test "matches the member-cancel predicate for every status" do
      expected = %{
        "requested" => true,
        "approved" => true,
        "rejected" => false,
        "cancelled" => false,
        "checked_out" => false,
        "returned" => false
      }

      for {status, cancellable?} <- expected do
        view = LoanProjection.member_view(loan(status), @today)
        assert view.cancellable? == cancellable?, status
        assert view.cancellable? == LoanPolicy.member_cancellable?(loan(status)), status
      end
    end
  end
end
