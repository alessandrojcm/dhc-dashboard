defmodule DhcWeb.TrainingAnnouncementsClientParityTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")

  setup_all do
    DhcWeb.ClientParity.require!(@client_root)
  end

  test "both slices have cookie security, the domain tag, SDK exports and query helpers",
       context do
    {:ok, spec} = YamlElixir.read_from_file(Application.app_dir(:dhc, "priv/api/openapi.yaml"))
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    query = File.read!(Path.join(context.generated, "@tanstack/svelte-query.gen.ts"))
    public = File.read!(context.public)

    for {slice, count} <- [{"trainingAnnouncements", 10}, {"trainingAnnouncementExceptions", 6}] do
      operations =
        for {_path, methods} <- spec["paths"],
            {method, operation} <- methods,
            is_map(operation),
            id = operation["operationId"],
            is_binary(id),
            String.starts_with?(id, slice <> "."),
            do: {method, operation}

      assert length(operations) == count

      for {method, operation} <- operations do
        assert operation["tags"] == ["TrainingAnnouncements"]
        assert operation["security"] == [%{"cookieSession" => []}]
        [namespace, action] = String.split(operation["operationId"], ".")

        function =
          namespace <> String.capitalize(String.first(action)) <> String.slice(action, 1..-1//1)

        assert sdk =~ "export const #{function} "
        assert public =~ ~r/\n\t#{function},\n/

        helpers =
          if method == "get", do: ["Options", "QueryKey"], else: ["Mutation", "MutationKey"]

        for suffix <- helpers do
          assert query =~ "export const #{function}#{suffix} "
          assert public =~ ~r/\n\t#{function}#{suffix},\n/
        end
      end
    end

    assert Enum.find(spec["tags"], &(&1["name"] == "TrainingAnnouncements"))
           |> Map.take(["x-context", "x-resource"]) == %{
             "x-context" => "Dhc.TrainingAnnouncements",
             "x-resource" => "Announcement"
           }

    assert spec["components"]["schemas"]["TrainingAnnouncementWarning"]["enum"] == [
             "slot_collision",
             "exception_intersection_changed"
           ]
  end

  test "response schedule fields are required nullable in the generated validator", context do
    validators = File.read!(Path.join(context.generated, "valibot.gen.ts"))

    [_before, response] =
      String.split(validators, "export const vTrainingAnnouncement = ", parts: 2)

    response = response |> String.split("\nexport ", parts: 2) |> hd()
    assert response =~ "weekday: v.nullable("
    assert response =~ "oneOffDate: v.nullable("
  end

  test "every Training Announcement schema and validator is publicly exported", context do
    {:ok, spec} = YamlElixir.read_from_file(Application.app_dir(:dhc, "priv/api/openapi.yaml"))
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    validators = File.read!(Path.join(context.generated, "valibot.gen.ts"))
    public = File.read!(context.public)

    for {name, _} <- spec["components"]["schemas"],
        String.starts_with?(name, "TrainingAnnouncement") do
      assert types =~ "export type #{name} ="
      assert validators =~ "export const v#{name} ="
      assert public =~ ~r/\n\t#{name},\n/
      assert public =~ ~r/\n\tv#{name},\n/
    end
  end
end
