defmodule DhcWeb.ClientParityTest do
  use ExUnit.Case, async: true

  test "returns generated and public paths when src/client exists" do
    tmp = tmpdir()

    try do
      File.mkdir_p!(Path.join(tmp, "src/client"))
      File.write!(Path.join(tmp, "src/index.ts"), "")

      assert {:ok, generated: generated, public: public} = DhcWeb.ClientParity.setup(tmp)
      assert generated == Path.join(tmp, "src/client")
      assert public == Path.join(tmp, "src/index.ts")
      assert {:ok, generated: ^generated, public: ^public} = DhcWeb.ClientParity.require!(tmp)
    after
      File.rm_rf!(tmp)
    end
  end

  test "setup returns {:skip, reason} when the generated client is missing" do
    tmp = tmpdir()

    try do
      File.mkdir_p!(tmp)

      assert {:skip, reason} = DhcWeb.ClientParity.setup(tmp)
      assert reason =~ "mise run api-gen"
    after
      File.rm_rf!(tmp)
    end
  end

  test "require! raises instead of stuffing skip onto the context" do
    tmp = tmpdir()

    try do
      File.mkdir_p!(tmp)

      assert_raise ArgumentError, ~r/mise run api-gen/, fn ->
        DhcWeb.ClientParity.require!(tmp)
      end
    after
      File.rm_rf!(tmp)
    end
  end

  test "the generated client directory is gitignored" do
    ignore = File.read!(Path.expand("../../../../.gitignore", __DIR__))
    assert ignore =~ "packages/api-client/src/client/"
  end

  defp tmpdir do
    Path.join(System.tmp_dir!(), "dhc-client-parity-#{System.unique_integer([:positive])}")
  end
end
