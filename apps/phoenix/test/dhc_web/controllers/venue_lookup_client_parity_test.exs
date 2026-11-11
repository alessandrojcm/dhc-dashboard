defmodule DhcWeb.VenueLookupClientParityTest do
  @moduledoc """
  ALE-442 client parity: the venue lookup operations, their closed shapes and
  every workshop read's selected-destination fields must be reachable from
  `@dhc/api-client`.

  `packages/api-client/src/index.ts` is hand-maintained, so a regenerated
  schema that is not re-exported exists yet cannot be imported. Reads the
  generated files as text on purpose: the risk is a missing name.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")

  setup_all do
    DhcWeb.ClientParity.require!(@client_root)
  end

  @tag :parity
  test "both lookup operations are generated and publicly re-exported", context do
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    public = File.read!(context.public)

    for function <- ~w(venueLookupSuggest venueLookupResolve) do
      assert sdk =~ "export const #{function}", "#{function} is missing — run `mise run api-gen`"
      assert public =~ ~r/\n\t#{function},\n/, "#{function} is not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "the closed lookup and credit shapes reach the public surface", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    public = File.read!(context.public)

    for schema <- ~w(DestinationAttribution VenueLookupSuggestion VenueLookupSelection) do
      assert types =~ "export type #{schema} =", "#{schema} is missing from the generated types"
      assert public =~ ~r/\n\t#{schema},\n/, "#{schema} is not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "every workshop read and destination request carries the selected place, not its credits",
       context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))

    for schema <- ~w(Workshop BeginnersWorkshop BeginnersIntakeWorkshop) do
      body = extract_type(types, schema)

      for field <- ~w(destinationProvider destinationPlaceId) do
        assert body =~ ~r/\b#{field}\b/, "#{schema} lacks #{field}"
      end

      # Only the Place ID is stored (ALE-442): no Google credits on a read.
      refute body =~ ~r/\bdestinationAttributions\b/, "#{schema} still carries credits"
    end

    for schema <- ~w(WorkshopManagementRequest WorkshopManagementUpdateRequest
                     BeginnersWorkshopDestinationRequest) do
      body = extract_type(types, schema)
      assert body =~ ~r/\bdestinationPlaceId\b/, "#{schema} lacks destinationPlaceId"
      refute body =~ ~r/\bdestinationAttributions\b/, "#{schema} still accepts credits"
    end
  end

  defp extract_type(types, name) do
    [_before, rest] = String.split(types, "export type #{name} = ", parts: 2)

    rest
    |> String.split("\nexport ", parts: 2)
    |> List.first()
  end
end
