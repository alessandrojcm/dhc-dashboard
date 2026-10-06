defmodule DhcWeb.RouterCapabilitiesTest do
  @moduledoc """
  ALE-344: every gated router pipeline declares one registry capability and
  is named after it, and the router names no roles.
  """
  use ExUnit.Case, async: true

  alias Dhc.Auth.Capabilities

  @router_path Path.expand("../../lib/dhc_web/router.ex", __DIR__)

  defp pipelines do
    {:ok, ast} = @router_path |> File.read!() |> Code.string_to_quoted()

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:pipeline, _, [name, [do: body]]} = node, acc ->
          {node, [{name, require_session_opts(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp require_session_opts(body) do
    {_body, acc} =
      Macro.prewalk(body, [], fn
        {:plug, _, [{:__aliases__, _, [:DhcWeb, :Plugs, :RequireSession]} | rest]} = node, acc ->
          {node, [List.first(rest, []) | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  test "every RequireSession pipeline names a registry capability after itself" do
    gated =
      for {name, [opts]} <- pipelines(), capability = Keyword.get(opts, :capability) do
        assert Capabilities.exists?(capability), "#{name}: unknown #{inspect(capability)}"
        refute Capabilities.owner_scoped?(capability), "#{name}: owner-scoped #{capability}"

        assert Atom.to_string(name) == String.replace(Atom.to_string(capability), ".", "_"),
               "pipeline #{name} must be named after #{capability}"

        capability
      end

    assert gated != []
    assert gated == Enum.uniq(gated), "one pipeline per capability"
  end

  test "RequireSession is only configured with a capability" do
    for {name, opts_list} <- pipelines(), opts <- opts_list do
      assert Keyword.keys(opts) -- [:capability] == [], "#{name} passes #{inspect(opts)}"
    end
  end

  test "the router contains no role names" do
    source = File.read!(@router_path)

    for role <-
          ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach) do
      refute source =~ ~r/\b#{role}\b/, "router.ex mentions #{role}"
    end

    refute source =~ "roles:"
  end
end
