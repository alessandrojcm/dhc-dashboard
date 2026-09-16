defmodule Dhc.Inventory.LoanProjection do
  @moduledoc """
  GH-508: the two read models a loan row becomes, and the only place either
  is built.

  The operator view names the borrower and always carries the container path;
  the member view withholds every operator fact and discloses the path only
  from approval onward (story 15). They are deliberately **not** one shape
  with fields stripped by role: a member projection built by subtraction
  would leak any field later added to the operator one (story 45).

  `Dhc.Inventory.AvailabilityCommands` projects every command outcome here,
  and the reads in `OperatorLoans`, `MemberLoans`, and `OperatorLoanQueue`
  reuse the same functions, so a command result, a detail read, and a queue
  row cannot disagree about status, overdue, or dates. `today` is a parameter
  so a batch read resolves the club's calendar day once.
  """

  alias Dhc.Inventory.Loan
  alias Dhc.Inventory.LoanPolicy

  @typedoc """
  One loan as an operator sees it. Must never be handed to a member read.
  """
  @type operator_loan :: %{
          id: String.t(),
          item_id: String.t(),
          borrower_principal_id: String.t(),
          status: String.t(),
          overdue?: boolean(),
          requested_start_on: Date.t(),
          requested_due_on: Date.t(),
          approved_start_on: Date.t() | nil,
          approved_due_on: Date.t() | nil,
          checked_out_at: DateTime.t() | nil,
          returned_at: DateTime.t() | nil,
          decided_at: DateTime.t() | nil,
          decided_by_principal_id: String.t() | nil,
          returned_by_principal_id: String.t() | nil,
          request_note: String.t() | nil,
          decision_note: String.t() | nil,
          item_slug: String.t(),
          item_label: String.t(),
          container_path: String.t() | nil,
          created_at: DateTime.t()
        }

  @typedoc """
  One loan as its borrower sees it.

  `item_*` are the retained snapshots captured at request time, not a live
  item read, so history stays readable after archival. `container_path` is
  present only once the loan is approved.
  """
  @type member_loan :: %{
          id: String.t(),
          item_id: String.t(),
          status: String.t(),
          overdue?: boolean(),
          requested_start_on: Date.t(),
          requested_due_on: Date.t(),
          approved_start_on: Date.t() | nil,
          approved_due_on: Date.t() | nil,
          checked_out_at: DateTime.t() | nil,
          returned_at: DateTime.t() | nil,
          request_note: String.t() | nil,
          decision_note: String.t() | nil,
          item_slug: String.t(),
          item_label: String.t(),
          container_path: String.t() | nil,
          created_at: DateTime.t()
        }

  # Statuses from which the borrower is (or was) entitled to the location.
  @path_disclosing_statuses ~w(approved checked_out returned)

  @doc """
  One loan row as an operator read model.
  """
  @spec operator_view(Loan.t(), Date.t()) :: operator_loan()
  def operator_view(%Loan{} = loan, %Date{} = today) do
    %{
      id: loan.id,
      item_id: loan.item_id,
      borrower_principal_id: loan.borrower_principal_id,
      status: loan.status,
      overdue?: LoanPolicy.overdue?(loan, today),
      requested_start_on: loan.requested_start_on,
      requested_due_on: loan.requested_due_on,
      approved_start_on: loan.approved_start_on,
      approved_due_on: loan.approved_due_on,
      checked_out_at: loan.checked_out_at,
      returned_at: loan.returned_at,
      decided_at: loan.decided_at,
      decided_by_principal_id: loan.decided_by_principal_id,
      returned_by_principal_id: loan.returned_by_principal_id,
      request_note: loan.request_note,
      decision_note: loan.decision_note,
      item_slug: loan.item_slug_snapshot,
      item_label: loan.item_label_snapshot,
      container_path: loan.approved_container_path_snapshot,
      created_at: loan.created_at
    }
  end

  @doc """
  One loan row as its borrower's read model.
  """
  @spec member_view(Loan.t(), Date.t()) :: member_loan()
  def member_view(%Loan{} = loan, %Date{} = today) do
    %{
      id: loan.id,
      item_id: loan.item_id,
      status: loan.status,
      overdue?: LoanPolicy.overdue?(loan, today),
      requested_start_on: loan.requested_start_on,
      requested_due_on: loan.requested_due_on,
      approved_start_on: loan.approved_start_on,
      approved_due_on: loan.approved_due_on,
      checked_out_at: loan.checked_out_at,
      returned_at: loan.returned_at,
      request_note: loan.request_note,
      decision_note: loan.decision_note,
      item_slug: loan.item_slug_snapshot,
      item_label: loan.item_label_snapshot,
      container_path: member_container_path(loan),
      created_at: loan.created_at
    }
  end

  # The container path is the borrower's collection entitlement, and only
  # once the loan is approved (story 15). Before approval there is no
  # entitlement, so the location stays hidden even though the row may
  # already carry a snapshot.
  defp member_container_path(%Loan{status: status, approved_container_path_snapshot: path})
       when status in @path_disclosing_statuses,
       do: path

  defp member_container_path(%Loan{}), do: nil
end
