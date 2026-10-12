defmodule DhcWeb.BeginnersWorkshopEmailTemplatesClientParityTest do
  @moduledoc """
  ALE-383 client parity: every Intake Email template operation in the
  contract is generated and reachable from `@dhc/api-client`'s
  hand-maintained public surface, and the contract's vocabulary matches
  Phoenix's `EmailType` table.
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")
  @slice "beginnersWorkshopEmailTemplates"

  setup_all do
    DhcWeb.ClientParity.require!(@client_root)
  end

  defp spec do
    {:ok, spec} = YamlElixir.read_from_file(Application.app_dir(:dhc, "priv/api/openapi.yaml"))
    spec
  end

  @tag :parity
  test "both operations have cookie security, the domain tag, SDK exports and query helpers",
       context do
    spec = spec()
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    query = File.read!(Path.join(context.generated, "@tanstack/svelte-query.gen.ts"))
    public = File.read!(context.public)

    operations =
      for {_path, methods} <- spec["paths"],
          {method, operation} <- methods,
          is_map(operation),
          id = operation["operationId"],
          is_binary(id),
          String.starts_with?(id, @slice <> "."),
          do: {method, operation}

    assert operations |> Enum.map(&elem(&1, 1)["operationId"]) |> Enum.sort() ==
             ["#{@slice}.list", "#{@slice}.update"]

    for {method, operation} <- operations do
      assert operation["tags"] == ["BeginnersWorkshops"]
      assert operation["security"] == [%{"cookieSession" => []}]
      [namespace, action] = String.split(operation["operationId"], ".")
      function = namespace <> String.capitalize(action)

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
  test "the template types reach the public surface", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    public = File.read!(context.public)

    for schema <- ~w(
          IntakeEmailDocument
          IntakeEmailKind
          IntakeEmailPlaceholder
          IntakeEmailTemplate
          IntakeEmailTemplateUpdate
          IntakeEmailTemplateValidationError
          IntakeEmailType
        ) do
      assert types =~ "export type #{schema} =", "#{schema} is missing from the generated types"

      assert public =~ ~r/\n\t#{schema},\n/,
             "#{schema} is generated but not re-exported from src/index.ts"
    end
  end

  test "the contract's types, placeholders and refusal codes match Phoenix" do
    schemas = spec()["components"]["schemas"]

    assert schemas["IntakeEmailType"]["enum"] == EmailType.ids()

    assert Enum.sort(schemas["IntakeEmailPlaceholder"]["enum"]) ==
             EmailType.maxima() |> Map.keys() |> Enum.sort()

    [_error, %{"properties" => %{"errors" => %{"properties" => %{"code" => code}}}}] =
      schemas["IntakeEmailTemplateValidationError"]["allOf"]

    assert code["enum"] == ~w(placeholder_not_allowed template_too_long invalid_template)
  end
end
