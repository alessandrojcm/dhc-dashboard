defmodule DhcWeb.InventoryMemberClientParityTest do
  @moduledoc """
  ALE-285 client parity: every member catalog and own-loan operation in the
  contract must be reachable from `@dhc/api-client`.

  `mise run api-gen` writes `packages/api-client/src/client/`, but the public
  surface in `packages/api-client/src/index.ts` is hand-maintained (see the
  API Client section of `docs/agents/commands.md`). Regenerating without
  extending those four export blocks leaves an operation that exists in
  `src/client/` yet cannot be imported — the exact drift this test catches,
  in the same suite as the contract tests rather than in a separate runner.

  It reads the generated files as text on purpose: asserting on TypeScript
  semantics is the frontend type-check's job, while the risk here is a
  missing name.

  This is the member twin of
  `DhcWeb.InventoryOperatorItemsClientParityTest`; both exist because a
  member operation and an operator operation can drift independently.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")
  # list + show + request, then own-loan list + show + cancel.
  @expected_operation_count 6

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
  test "every member inventory operation is generated and publicly re-exported", context do
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    public = File.read!(context.public)

    operations = operation_ids()

    assert Enum.count(operations) == @expected_operation_count,
           "expected the full member operation set, got: #{inspect(operations)}"

    for operation <- operations do
      function = sdk_function_name(operation)

      assert sdk =~ "export const #{function}",
             "#{operation} is missing from the generated SDK — run `mise run api-gen`"

      assert public =~ ~r/\n\t#{function},\n/,
             "#{function} is generated but not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "the member viewer and typed error schemas reach the public surface", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    public = File.read!(context.public)

    # The member read models, the request/cancel bodies, and the generic
    # conflict codes are the schemas a consumer cannot hand-roll.
    for schema <- ~w(
          InventoryCatalogItem
          InventoryCatalogAvailability
          InventoryCatalogCategoryRef
          InventoryCatalogItemListResponse
          InventoryLoanRequestRequest
          InventoryLoanCancelRequest
          InventoryMemberLoan
          InventoryMemberLoanListResponse
          InventoryMemberLoanConflictError
          InventoryMemberLoanValidationError
        ) do
      assert types =~ "export type #{schema} =",
             "#{schema} is missing from the generated types"

      assert public =~ ~r/\n\t#{schema},\n/,
             "#{schema} is generated but not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "query and mutation helpers exist for member reads and commands", context do
    query = File.read!(Path.join(context.generated, "@tanstack/svelte-query.gen.ts"))
    public = File.read!(context.public)

    helpers = ~w(
      inventoryCatalogListItemsOptions
      inventoryCatalogListItemsQueryKey
      inventoryCatalogListItemsInfiniteOptions
      inventoryCatalogShowItemOptions
      inventoryCatalogRequestLoanMutation
      inventoryMemberLoansListOptions
      inventoryMemberLoansListQueryKey
      inventoryMemberLoansShowOptions
      inventoryMemberLoansCancelMutation
    )

    for helper <- helpers do
      assert query =~ "export const #{helper}",
             "#{helper} is missing from the generated TanStack helpers"

      assert public =~ ~r/\n\t#{helper},\n/,
             "#{helper} is generated but not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "the member catalog type cannot express the operator-only fields", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))

    # The privacy boundary must survive code generation: a consumer holding an
    # InventoryCatalogItem must not be able to read a container, operator
    # notes, or archive state off it (spec ALE-280 story 45). Asserting on the
    # generated type is what proves the *contract* — not merely the renderer —
    # keeps those fields out.
    catalog_type = extract_type(types, "InventoryCatalogItem")

    for forbidden <- ~w(container containerId notes archivedAt outForMaintenance quantity
                        borrower borrowerPrincipalId) do
      refute catalog_type =~ forbidden,
             "InventoryCatalogItem must not expose #{forbidden}"
    end

    # Same for the member loan: no borrower and no deciding operator.
    loan_type = extract_type(types, "InventoryMemberLoan")

    for forbidden <- ~w(borrowerPrincipalId decidedByPrincipalId returnedByPrincipalId decidedAt) do
      refute loan_type =~ forbidden, "InventoryMemberLoan must not expose #{forbidden}"
    end
  end

  # Derived from the spec so a renamed or dropped operation fails here rather
  # than silently losing its client function.
  defp operation_ids do
    path = Application.app_dir(:dhc, "priv/api/openapi.yaml")
    {:ok, spec} = YamlElixir.read_from_file(path)

    for {path, methods} <- spec["paths"],
        String.starts_with?(path, "/inventory/catalog/items") or
          String.starts_with?(path, "/inventory/loans/mine"),
        {_method, operation} <- methods,
        is_map(operation),
        id = operation["operationId"],
        is_binary(id),
        do: id
  end

  # `inventoryCatalog.listItems` → `inventoryCatalogListItems`
  defp sdk_function_name(operation_id) do
    [namespace, action] = String.split(operation_id, ".", parts: 2)

    namespace <>
      String.replace_prefix(action, String.first(action), String.upcase(String.first(action)))
  end

  # The generated file declares one type per `export type X = {...};` block, so
  # the body is everything up to the next top-level `export`.
  defp extract_type(types, name) do
    [_before, rest] = String.split(types, "export type #{name} = ", parts: 2)

    rest
    |> String.split("\nexport ", parts: 2)
    |> List.first()
  end
end
