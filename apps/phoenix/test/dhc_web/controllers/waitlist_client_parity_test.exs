defmodule DhcWeb.WaitlistClientParityTest do
  @moduledoc """
  ALE-375 client parity: the Waitlist standing reshape must reach
  `@dhc/api-client`, so the dashboard cannot keep sending a status edit or
  reading a legacy status the contract no longer has.

  Reads the generated files as text on purpose: the risk here is a stale
  generated client or a missing re-export, not TypeScript semantics.
  """

  use ExUnit.Case, async: true

  alias Dhc.Waitlist.Standing

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")

  setup_all do
    DhcWeb.ClientParity.require!(@client_root)
  end

  @tag :parity
  test "the generated WaitlistStatus is the five standings", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    [_, body] = Regex.run(~r/export const WaitlistStatus = \{(.*?)\} as const;/s, types)
    values = Regex.scan(~r/'([a-z_]+)'/, body) |> Enum.map(&List.last/1)

    assert values == Standing.statuses()
  end

  @tag :parity
  test "the update request carries admin notes only", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    [_, body] = Regex.run(~r/export type WaitlistEntryUpdateRequest = \{(.*?)\};/s, types)

    assert body =~ "adminNotes: string | null;"
    refute body =~ "status"
  end

  @tag :parity
  test "entries expose removedAt and list only waiting or removed people", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))

    [_, entry] = Regex.run(~r/export type WaitlistEntry = \{(.*?)\n\};/s, types)
    assert entry =~ "removedAt: string | null;"

    [_, data] = Regex.run(~r/export type WaitlistEntriesData = \{(.*?)\n\};/s, types)
    assert data =~ "status?: 'waiting' | 'removed';"
  end

  @tag :parity
  test "ALE-376: the client restores entries, caps firstName and sends invite objects only",
       context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    sdk = File.read!(Path.join(context.generated, "sdk.gen.ts"))
    valibot = File.read!(Path.join(context.generated, "valibot.gen.ts"))
    public = File.read!(context.public)

    assert sdk =~
             ~r/export const waitlistRestoreEntry = .*url: '\/waitlist\/entries\/\{id\}\/restore'/s

    [_, request] = Regex.run(~r/export type InvitationCreateRequest = \{(.*?)\n\};/s, types)
    assert request =~ "invites: Array<InvitationCreateInvite>;"

    [_, create] =
      Regex.run(~r/export const vWaitlistEntryCreateRequest = v.object\(\{(.*?)\n\}\);/s, valibot)

    assert create =~ ~r/firstName: v.pipe\(v.string\(\), v.minLength\(1\), v.maxLength\(40\)\)/

    for name <- ~w(waitlistRestoreEntry waitlistRestoreEntryMutation WaitlistRestoreEntryData) do
      assert public =~ ~r/\n\t#{name},\n/, "#{name} is not re-exported from src/index.ts"
    end
  end

  @tag :parity
  test "the generated AuthCapability names beginners.waitlist.manage", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    public = File.read!(context.public)

    assert types =~ "'beginners.waitlist.manage'"
    refute types =~ "beginners.workshop.read"

    for name <- ~w(WaitlistStatus WaitlistEntry WaitlistEntryUpdateRequest AuthCapability) do
      assert public =~ ~r/\n\t#{name},\n/, "#{name} is not re-exported from src/index.ts"
    end
  end
end
