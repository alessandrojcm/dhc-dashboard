defmodule Mix.Tasks.Gen.ControllersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Gen.Controllers

  @fixture_path "test/fixtures/minimal_spec.yaml"

  setup do
    spec = parse_fixture!()
    %{spec: spec}
  end

  # ── Parsing ──────────────────────────────────────────────────────────

  test "parses the fixture spec into an OpenApi struct" do
    spec = parse_fixture!()

    assert %OpenApiSpex.OpenApi{} = spec
    assert %OpenApiSpex.Info{title: "DHC Dashboard API (test fixture)"} = spec.info
    assert is_map(spec.paths)
  end

  # ── unique_tags/1 ────────────────────────────────────────────────────

  test "unique_tags returns sorted unique tags", %{spec: spec} do
    tags = Controllers.unique_tags(spec)

    assert tags == ["Health"]
  end

  # ── operations_for_tag/2 ─────────────────────────────────────────────

  test "operations_for_tag returns all operations for a given tag", %{spec: spec} do
    operations = Controllers.operations_for_tag(spec, "Health")

    assert length(operations) == 2

    index_op = Enum.find(operations, &(&1.operation_id == "health.index"))
    show_op = Enum.find(operations, &(&1.operation_id == "health.show"))

    assert index_op
    assert index_op.method == :get
    assert index_op.path == "/health"

    assert show_op
    assert show_op.method == :get
    assert show_op.path == "/health/detailed"
  end

  # ── controller_module/1 ──────────────────────────────────────────────

  test "controller_module derives the correct module name from a tag" do
    assert Controllers.controller_module("Health") == "DhcWeb.HealthController"
    assert Controllers.controller_module("Members") == "DhcWeb.MembersController"
  end

  # ── json_module/1 ────────────────────────────────────────────────────

  test "json_module derives the correct module name from a tag" do
    assert Controllers.json_module("Health") == "DhcWeb.HealthJSON"
    assert Controllers.json_module("Members") == "DhcWeb.MembersJSON"
  end

  # ── operation_id_to_action/1 ─────────────────────────────────────────

  test "operation_id_to_action extracts the action name from operationId" do
    assert Controllers.operation_id_to_action("health.index") == "index"
    assert Controllers.operation_id_to_action("health.show") == "show"
    assert Controllers.operation_id_to_action("members.create") == "create"
  end

  test "operation_id_to_action returns the full id if no dot separator" do
    assert Controllers.operation_id_to_action("health") == "health"
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp parse_fixture! do
    path = Path.join(File.cwd!(), @fixture_path)
    assert File.exists?(path), "Fixture spec not found: #{path}"

    raw_map =
      case YamlElixir.read_from_string(File.read!(path)) do
        {:ok, spec} -> spec
        {:error, error} -> raise "Failed to parse fixture: #{inspect(error)}"
      end

    OpenApiSpex.OpenApi.Decode.decode(raw_map)
  end
end
