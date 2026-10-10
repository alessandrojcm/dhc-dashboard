defmodule DhcWeb.BeginnersWorkshopIntakeClientParityTest do
  @moduledoc """
  ALE-381 client parity: every public Intake link operation in the contract
  is generated and reachable from `@dhc/api-client`'s hand-maintained public
  surface; each is public (no security), documents `Referrer-Policy:
  no-referrer` on every response, and the safe-view vocabulary matches
  `Dhc.BeginnersWorkshops.IntakePage`.
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakePage

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")
  @slice "beginnersWorkshopIntake"

  setup_all do
    DhcWeb.ClientParity.require!(@client_root)
  end

  defp spec do
    {:ok, spec} = YamlElixir.read_from_file(Application.app_dir(:dhc, "priv/api/openapi.yaml"))
    spec
  end

  defp resolve(spec, %{"$ref" => "#/components/" <> path}),
    do: get_in(spec, ["components" | String.split(path, "/")])

  defp resolve(_spec, other), do: other

  @tag :parity
  test "every operation is public, sends no-referrer, and is exported with its query helpers",
       context do
    spec = spec()
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    query = File.read!(Path.join(context.generated, "@tanstack/svelte-query.gen.ts"))
    public = File.read!(context.public)

    operations =
      for {path, methods} <- spec["paths"],
          {method, operation} <- methods,
          is_map(operation),
          id = operation["operationId"],
          is_binary(id),
          String.starts_with?(id, @slice <> "."),
          do: {path, method, operation}

    assert operations |> Enum.map(&elem(&1, 2)["operationId"]) |> Enum.sort() ==
             ["#{@slice}.returnFromCheckout", "#{@slice}.show", "#{@slice}.startPayment"]

    for {path, method, operation} <- operations do
      assert String.starts_with?(path, "/beginners/intake/{token}")
      assert operation["tags"] == ["BeginnersWorkshops"]
      assert operation["security"] == []

      for {status, response} <- operation["responses"] do
        response = resolve(spec, response)

        assert %{"Referrer-Policy" => _} = response["headers"] || %{},
               "#{operation["operationId"]} #{status} does not document Referrer-Policy"
      end

      [namespace, action] = String.split(operation["operationId"], ".")

      function =
        namespace <> String.upcase(String.first(action)) <> String.slice(action, 1..-1//1)

      assert sdk =~ "export const #{function} "
      assert public =~ ~r/\n\t#{function},\n/

      helpers = if method == "get", do: ["Options", "QueryKey"], else: ["Mutation", "MutationKey"]

      for suffix <- helpers do
        assert query =~ "export const #{function}#{suffix} "
        assert public =~ ~r/\n\t#{function}#{suffix},\n/
      end
    end
  end

  @tag :parity
  test "the safe-view types reach the public surface", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    public = File.read!(context.public)

    for schema <- ~w(
          BeginnersIntakeAction
          BeginnersIntakeClosedReason
          BeginnersIntakeConflictError
          BeginnersIntakePage
          BeginnersIntakeState
          BeginnersIntakeWorkshop
        ) do
      assert types =~ "export type #{schema} =", "#{schema} is missing from the generated types"

      assert public =~ ~r/\n\t#{schema},\n/,
             "#{schema} is generated but not re-exported from src/index.ts"
    end
  end

  test "the contract's states match the read model" do
    schemas = spec()["components"]["schemas"]
    assert schemas["BeginnersIntakeState"]["enum"] == Enum.map(IntakePage.states(), &to_string/1)
    refute Map.has_key?(schemas["BeginnersIntakePage"]["properties"], "id")
  end
end
