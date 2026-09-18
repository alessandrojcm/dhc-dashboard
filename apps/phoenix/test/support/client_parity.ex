defmodule DhcWeb.ClientParity do
  @moduledoc """
  Shared setup for generated-client parity tests.

  `packages/api-client/src/client/` is gitignored. ExUnit 1.20 only skips via
  `@tag skip:` (evaluated before `setup`), so a missing client cannot be
  skipped from `setup_all`. `mise run phx-test` generates the client before
  `mix test`. Locally, `require!/1` raises instead of letting
  `context.generated` KeyError.
  """

  @spec setup(Path.t()) :: {:ok, keyword()} | {:skip, String.t()}
  def setup(client_root) do
    generated = Path.join(client_root, "src/client")

    if File.dir?(generated) do
      {:ok, generated: generated, public: Path.join(client_root, "src/index.ts")}
    else
      {:skip, "generated client absent — run `mise run api-gen`"}
    end
  end

  @spec require!(Path.t()) :: {:ok, keyword()}
  def require!(client_root) do
    case setup(client_root) do
      {:ok, assigns} -> {:ok, assigns}
      {:skip, reason} -> raise ArgumentError, reason
    end
  end
end
