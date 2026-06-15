defmodule Mix.Tasks.Gen.ControllersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Gen.Controllers

  @minimal_fixture "test/fixtures/minimal_spec.yaml"
  @crud_fixture "test/fixtures/crud_spec.yaml"

  setup do
    minimal_spec = parse_fixture!(@minimal_fixture)
    crud_spec = parse_fixture!(@crud_fixture)
    %{spec: minimal_spec, crud_spec: crud_spec}
  end

  # ── Parsing ──────────────────────────────────────────────────────────

  test "parses the minimal fixture spec into an OpenApi struct" do
    spec = parse_fixture!(@minimal_fixture)

    assert %OpenApiSpex.OpenApi{} = spec
    assert %OpenApiSpex.Info{title: "DHC Dashboard API (test fixture)"} = spec.info
    assert is_map(spec.paths)
  end

  test "parses the CRUD fixture spec into an OpenApi struct" do
    spec = parse_fixture!(@crud_fixture)

    assert %OpenApiSpex.OpenApi{} = spec
    assert %OpenApiSpex.Info{title: "DHC Dashboard API (CRUD test fixture)"} = spec.info
    assert is_map(spec.paths)
    assert is_map(spec.components.schemas)
  end

  # ── unique_tags/1 ────────────────────────────────────────────────────

  test "unique_tags returns sorted unique tags for minimal spec", %{spec: spec} do
    tags = Controllers.unique_tags(spec)

    assert tags == ["Health"]
  end

  test "unique_tags returns multiple sorted unique tags for CRUD spec", %{crud_spec: spec} do
    tags = Controllers.unique_tags(spec)

    assert tags == ["Gadgets", "Widgets"]
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

  test "operations_for_tag returns all CRUD operations for Widgets", %{crud_spec: spec} do
    operations = Controllers.operations_for_tag(spec, "Widgets")

    assert length(operations) == 6

    action_names =
      operations
      |> Enum.map(&Controllers.operation_id_to_action(&1.operation_id))
      |> Enum.sort()

    assert action_names == ["create", "delete", "index", "renew", "show", "update"]
  end

  test "operations_for_tag returns list-only operations for Gadgets", %{crud_spec: spec} do
    operations = Controllers.operations_for_tag(spec, "Gadgets")

    assert length(operations) == 1
    assert hd(operations).operation_id == "gadgets.index"
    assert hd(operations).method == :get
    assert hd(operations).path == "/gadgets"
  end

  # ── controller_module/1 ──────────────────────────────────────────────

  test "controller_module derives the correct module name from a tag" do
    assert Controllers.controller_module("Health") == "DhcWeb.HealthController"
    assert Controllers.controller_module("Members") == "DhcWeb.MembersController"
    assert Controllers.controller_module("Widgets") == "DhcWeb.WidgetsController"
    assert Controllers.controller_module("Gadgets") == "DhcWeb.GadgetsController"
  end

  # ── json_module/1 ────────────────────────────────────────────────────

  test "json_module derives the correct module name from a tag" do
    assert Controllers.json_module("Health") == "DhcWeb.HealthJSON"
    assert Controllers.json_module("Members") == "DhcWeb.MembersJSON"
    assert Controllers.json_module("Widgets") == "DhcWeb.WidgetsJSON"
  end

  # ── operation_id_to_action/1 ─────────────────────────────────────────

  test "operation_id_to_action extracts the action name from operationId" do
    assert Controllers.operation_id_to_action("health.index") == "index"
    assert Controllers.operation_id_to_action("health.show") == "show"
    assert Controllers.operation_id_to_action("members.create") == "create"
    assert Controllers.operation_id_to_action("widgets.renew") == "renew"
  end

  test "operation_id_to_action returns the full id if no dot separator" do
    assert Controllers.operation_id_to_action("health") == "health"
  end

  # ── action_from_http/2 ───────────────────────────────────────────────

  describe "action_from_http/2 REST mappings" do
    test "GET /resources → index" do
      assert Controllers.action_from_http(:get, "/widgets") == "index"
      assert Controllers.action_from_http(:get, "/health") == "index"
    end

    test "GET /resources/{id} → show" do
      assert Controllers.action_from_http(:get, "/widgets/{id}") == "show"
      assert Controllers.action_from_http(:get, "/members/{member_id}") == "show"
    end

    test "POST /resources → create" do
      assert Controllers.action_from_http(:post, "/widgets") == "create"
    end

    test "PUT /resources/{id} → update" do
      assert Controllers.action_from_http(:put, "/widgets/{id}") == "update"
    end

    test "PATCH /resources/{id} → update" do
      assert Controllers.action_from_http(:patch, "/widgets/{id}") == "update"
    end

    test "DELETE /resources/{id} → delete" do
      assert Controllers.action_from_http(:delete, "/widgets/{id}") == "delete"
    end

    test "non-REST paths derive action from last non-param segment" do
      assert Controllers.action_from_http(:post, "/widgets/{id}/renew") == "renew"
      assert Controllers.action_from_http(:post, "/members/{id}/renew") == "renew"
    end

    test "non-REST paths with multiple non-param segments use the last one" do
      assert Controllers.action_from_http(:post, "/orders/{id}/items/{item_id}/cancel") ==
               "cancel"
    end
  end

  # ── Argument parsing ─────────────────────────────────────────────────

  describe "parse_args/1" do
    test "no flags returns force: false" do
      assert Controllers.parse_args([]) == %{force: false}
    end

    test "--force with no value returns force: :all" do
      assert Controllers.parse_args(["--force"]) == %{force: :all}
    end

    test "--force=path returns force: path" do
      assert Controllers.parse_args(["--force=lib/foo_controller.ex"]) ==
               %{force: "lib/foo_controller.ex"}
    end

    test "unknown flags are ignored" do
      assert Controllers.parse_args(["--verbose", "--force"]) == %{force: :all}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp parse_fixture!(path) do
    full_path = Path.join(File.cwd!(), path)
    assert File.exists?(full_path), "Fixture spec not found: #{full_path}"

    raw_map =
      case YamlElixir.read_from_string(File.read!(full_path)) do
        {:ok, spec} -> spec
        {:error, error} -> raise "Failed to parse fixture: #{inspect(error)}"
      end

    OpenApiSpex.OpenApi.Decode.decode(raw_map)
  end
end
