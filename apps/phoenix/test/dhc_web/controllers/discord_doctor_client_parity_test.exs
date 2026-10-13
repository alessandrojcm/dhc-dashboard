defmodule DhcWeb.DiscordDoctorClientParityTest do
  @moduledoc """
  ALE-419 client parity: the Discord Doctor operations and the kick decision
  types the page reads must be reachable from `@dhc/api-client`.

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
  test "both Discord Doctor operations are generated and publicly re-exported", context do
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    query = File.read!(Path.join(context.generated, "@tanstack/svelte-query.gen.ts"))
    public = File.read!(context.public)

    for function <- ~w(discordDoctorReport discordDoctorKick) do
      assert sdk =~ "export const #{function}", "#{function} is missing — run `mise run api-gen`"
      assert public =~ ~r/\n\t#{function},\n/, "#{function} is not re-exported from src/index.ts"
    end

    for helper <- ~w(discordDoctorReportOptions discordDoctorKickMutation) do
      assert query =~ "export const #{helper}", "#{helper} is missing from the TanStack helpers"
      assert public =~ ~r/\n\t#{helper},\n/, "#{helper} is not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "the kick decision and audit-reason types reach the public surface", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    public = File.read!(context.public)

    for schema <- ~w(
          DiscordDoctorKick
          DiscordDoctorKickReasons
          DiscordDoctorKickResult
          DiscordDoctorReport
          DiscordDoctorServerMember
        ) do
      assert types =~ "export type #{schema} =", "#{schema} is missing from the generated types"
      assert public =~ ~r/\n\t#{schema},\n/, "#{schema} is not re-exported from src/index.ts"
    end

    assert extract_type(types, "DiscordDoctorServerMember") =~ ~r/\bkickRefusal\b/
    assert extract_type(types, "DiscordDoctorKickResult") =~ ~r/\bauditReason\b/
  end

  defp extract_type(types, name) do
    [_before, rest] = String.split(types, "export type #{name} = ", parts: 2)

    rest
    |> String.split("\nexport ", parts: 2)
    |> List.first()
  end
end
