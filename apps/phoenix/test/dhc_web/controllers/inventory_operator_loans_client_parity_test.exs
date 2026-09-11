defmodule DhcWeb.InventoryOperatorLoansClientParityTest do
  @moduledoc """
  ALE-298 client parity: every operator loan and queue operation in the
  contract must be reachable from `@dhc/api-client`.

  `mise run api-gen` writes `packages/api-client/src/client/`, but the public
  surface in `packages/api-client/src/index.ts` is hand-maintained (see the
  API Client section of `docs/agents/commands.md`). Regenerating without
  extending those four export blocks leaves an operation that exists in
  `src/client/` yet cannot be imported — the exact drift this test catches.

  It reads the generated files as text on purpose: asserting on TypeScript
  semantics is the frontend type-check's job, while the risk here is a
  missing name.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")
  # show + approve/reject/cancel/checkout/return/editDates, plus the queue.
  @expected_operation_count 8

  setup_all do
    generated = Path.join(@client_root, "src/client")

    # The generated client is gitignored, so a checkout that has not run
    # `mise run api-gen` has nothing to compare against. Skip explicitly via
    # ExUnit rather than passing a vacuous assertion, so a wrong path shows up
    # as a skipped test instead of a silent green one.
    if File.dir?(generated) do
      {:ok, generated: generated, public: Path.join(@client_root, "src/index.ts")}
    else
      {:ok, skip: "generated client absent — run `mise run api-gen`"}
    end
  end

  setup context do
    if context[:skip], do: {:ok, skip: true}, else: :ok
  end

  @tag :parity
  test "every operator loan and queue operation is generated and publicly re-exported",
       context do
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    public = File.read!(context.public)

    operations = operation_ids()

    assert Enum.count(operations) == @expected_operation_count,
           "expected the full operator loan operation set, got: #{inspect(operations)}"

    for operation <- operations do
      function = sdk_function_name(operation)

      assert sdk =~ "export const #{function}",
             "#{operation} is missing from the generated SDK — run `mise run api-gen`"

      assert public =~ ~r/\n\t#{function},\n/,
             "#{function} is generated but not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "the operator loan viewer, queue, and typed error schemas reach the public surface",
       context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    public = File.read!(context.public)

    for schema <- ~w(
          InventoryOperatorLoan
          InventoryOperatorLoanHandover
          InventoryOperatorLoanMaintenanceRow
          InventoryOperatorLoanQueue
          InventoryOperatorLoanConflictError
          InventoryOperatorLoanValidationError
          InventoryOperatorLoanApproveRequest
          InventoryOperatorLoanDatesRequest
        ) do
      assert types =~ "export type #{schema} =",
             "#{schema} is missing from the generated types"

      assert public =~ ~r/\n\t#{schema},\n/,
             "#{schema} is generated but not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "query and mutation helpers exist for operator loan reads and commands", context do
    query = File.read!(Path.join(context.generated, "@tanstack/svelte-query.gen.ts"))
    public = File.read!(context.public)

    helpers = ~w(
      inventoryOperatorLoansShowOptions
      inventoryOperatorLoansApproveMutation
      inventoryOperatorLoansRejectMutation
      inventoryOperatorLoansCancelMutation
      inventoryOperatorLoansCheckoutMutation
      inventoryOperatorLoansReturnMutation
      inventoryOperatorLoansEditDatesMutation
      inventoryOperatorLoanQueueShowOptions
    )

    for helper <- helpers do
      assert query =~ "export const #{helper}",
             "#{helper} is missing from the generated TanStack helpers"

      assert public =~ ~r/\n\t#{helper},\n/,
             "#{helper} is generated but not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "the operator loan type names the borrower and the member type still cannot",
       context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))

    operator_type = extract_type(types, "InventoryOperatorLoan")
    assert operator_type =~ "borrowerPrincipalId"

    member_type = extract_type(types, "InventoryMemberLoan")

    for forbidden <- ~w(borrowerPrincipalId decidedByPrincipalId returnedByPrincipalId decidedAt) do
      refute member_type =~ forbidden, "InventoryMemberLoan must not expose #{forbidden}"
    end
  end

  # Derived from the spec so a renamed or dropped operation fails here rather
  # than silently losing its client function.
  defp operation_ids do
    path = Application.app_dir(:dhc, "priv/api/openapi.yaml")
    {:ok, spec} = YamlElixir.read_from_file(path)

    for {path, methods} <- spec["paths"],
        String.starts_with?(path, "/inventory/operator/loans"),
        {_method, operation} <- methods,
        is_map(operation),
        id = operation["operationId"],
        is_binary(id),
        do: id
  end

  # `inventoryOperatorLoans.show` → `inventoryOperatorLoansShow`
  defp sdk_function_name(operation_id) do
    [namespace, action] = String.split(operation_id, ".", parts: 2)

    namespace <>
      String.replace_prefix(action, String.first(action), String.upcase(String.first(action)))
  end

  defp extract_type(types, name) do
    [_before, rest] = String.split(types, "export type #{name} = ", parts: 2)

    rest
    |> String.split("\nexport ", parts: 2)
    |> List.first()
  end
end
