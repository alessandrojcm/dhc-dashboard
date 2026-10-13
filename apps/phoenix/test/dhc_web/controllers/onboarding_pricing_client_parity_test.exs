defmodule DhcWeb.OnboardingPricingClientParityTest do
  @moduledoc """
  ALE-423 client parity: the handle-bound pricing read carries Phoenix's
  billing start dates, so the generated client must require them as civil
  dates and the public surface must re-export the pricing schema and helpers.
  Reads the generated files as text on purpose: the risk is a missing or
  optional field, not TypeScript semantics.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @client_root Path.join(@repo_root, "packages/api-client")

  setup_all do
    DhcWeb.ClientParity.require!(@client_root)
  end

  @tag :parity
  test "the pricing schema requires both billing start dates as civil dates", context do
    types = File.read!(Path.join(context.generated, "types.gen.ts"))
    valibot = File.read!(Path.join(context.generated, "valibot.gen.ts"))

    type = extract(types, "export type InvitationPricing = ")
    schema = extract(valibot, "export const vInvitationPricing = ")

    for field <- ~w(monthlyBillingStart annualBillingStart) do
      assert type =~ ~r/\b#{field}: string;/, "#{field} must be a required string"
      assert schema =~ "#{field}: v.pipe(v.string(), v.isoDate())"
    end
  end

  @tag :parity
  test "the pricing read and its schema reach the public surface", context do
    public = File.read!(context.public)

    for name <- ~w(onboardingPreviewPricing InvitationPricing InvitationPricingResponse) do
      assert public =~ ~r/\n\t#{name},\n/, "#{name} is not re-exported from src/index.ts"
    end
  end

  defp extract(source, marker) do
    [_before, rest] = String.split(source, marker, parts: 2)

    rest
    |> String.split("\nexport ", parts: 2)
    |> List.first()
  end
end
