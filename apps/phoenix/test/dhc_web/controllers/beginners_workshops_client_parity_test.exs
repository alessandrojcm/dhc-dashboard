defmodule DhcWeb.BeginnersWorkshopsClientParityTest do
  @moduledoc """
  ALE-378: the Beginners' Workshops contract and the generated client agree —
  one tag, cookie security, `<slice>.<action>` ids, SDK exports and query
  helpers, every schema and validator exported, and the closed vocabularies
  matching Phoenix.
  """
  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.WorkshopPolicy

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")

  setup_all do
    DhcWeb.ClientParity.require!(@client_root)
  end

  defp spec do
    {:ok, spec} = YamlElixir.read_from_file(Application.app_dir(:dhc, "priv/api/openapi.yaml"))
    spec
  end

  test "every operation is on the one tag with cookie security, SDK exports and query helpers",
       context do
    spec = spec()
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    query = File.read!(Path.join(context.generated, "@tanstack/svelte-query.gen.ts"))
    public = File.read!(context.public)

    operations =
      for {path, methods} <- spec["paths"],
          String.starts_with?(path, "/beginners-workshops"),
          {method, operation} <- methods,
          is_map(operation),
          is_binary(operation["operationId"]),
          do: {method, operation}

    # ALE-383's Intake Email template slice shares the one tag and URL root.
    assert operations |> Enum.map(&elem(&1, 1)["operationId"]) |> Enum.sort() ==
             ~w(beginnersWorkshopAssignments.list beginnersWorkshopDoor.show
                beginnersWorkshopEmailTemplates.list beginnersWorkshopEmailTemplates.update
                beginnersWorkshops.list beginnersWorkshops.schedule beginnersWorkshops.setStaff
                beginnersWorkshops.staffCandidates beginnersWorkshops.updateSettings)

    for {method, operation} <- operations do
      assert operation["tags"] == ["BeginnersWorkshops"]
      assert operation["security"] == [%{"cookieSession" => []}]
      [namespace, action] = String.split(operation["operationId"], ".")

      function =
        namespace <> String.capitalize(String.first(action)) <> String.slice(action, 1..-1//1)

      assert sdk =~ "export const #{function} "
      assert public =~ ~r/\n\t#{function},\n/

      helpers = if method == "get", do: ["Options", "QueryKey"], else: ["Mutation", "MutationKey"]

      for suffix <- helpers do
        assert query =~ "export const #{function}#{suffix} "
        assert public =~ ~r/\n\t#{function}#{suffix},\n/
      end
    end

    assert Enum.find(spec["tags"], &(&1["name"] == "BeginnersWorkshops"))
           |> Map.take(["x-context", "x-resource"]) == %{
             "x-context" => "Dhc.BeginnersWorkshops",
             "x-resource" => "BeginnersWorkshop"
           }
  end

  test "every Beginners' Workshop schema and validator is publicly exported", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    validators = File.read!(Path.join(context.generated, "valibot.gen.ts"))
    public = File.read!(context.public)

    for {name, _} <- spec()["components"]["schemas"],
        String.starts_with?(name, "BeginnersWorkshop") do
      assert types =~ "export type #{name} ="
      assert validators =~ "export const v#{name} ="
      assert public =~ ~r/\n\t#{name},\n/
      assert public =~ ~r/\n\tv#{name},\n/
    end
  end

  test "the stage and alert vocabularies are Phoenix's" do
    schemas = spec()["components"]["schemas"]

    assert schemas["BeginnersWorkshopStage"]["enum"] ==
             Enum.map(WorkshopPolicy.stages(), &Atom.to_string/1)

    assert schemas["BeginnersWorkshopAlert"]["enum"] ==
             Enum.map(WorkshopPolicy.alerts(), &Atom.to_string/1)
  end

  test "every refusal code in the contract is a declared problem reason" do
    schemas = spec()["components"]["schemas"]

    codes =
      for name <- ~w(BeginnersWorkshopConflictError BeginnersWorkshopInvalidError),
          code <-
            get_in(schemas, [
              name,
              "allOf",
              Access.at(1),
              "properties",
              "errors",
              "properties",
              "code",
              "enum"
            ]),
          do: code

    assert codes != []

    # Load the family before String.to_existing_atom/1: run alone, nothing has loaded it yet.
    Code.ensure_loaded!(DhcWeb.BeginnersWorkshopsHTTP)

    # The HTTP family renders each one with its code, without raising.
    for code <- codes do
      conn = Plug.Test.conn(:post, "/") |> Phoenix.Controller.put_format("json")
      conn = DhcWeb.BeginnersWorkshopsHTTP.call(conn, {:error, String.to_existing_atom(code)})
      assert %{"errors" => %{"code" => ^code}} = Jason.decode!(conn.resp_body)
    end
  end
end
