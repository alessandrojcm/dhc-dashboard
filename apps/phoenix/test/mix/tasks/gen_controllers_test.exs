defmodule Mix.Tasks.Gen.ControllersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Gen.Controllers

  @minimal_fixture "test/fixtures/minimal_spec.yaml"
  @crud_fixture "test/fixtures/crud_spec.yaml"
  @multi_resource_fixture "test/fixtures/multi_resource_spec.yaml"

  setup do
    minimal_spec = parse_fixture!(@minimal_fixture)
    crud_spec = parse_fixture!(@crud_fixture)
    multi_resource_spec = parse_fixture!(@multi_resource_fixture)

    # `tag_extension/2` reads the stashed spec from the process dictionary,
    # exactly as `run/1` does. Stash each spec under test so the private
    # naming helpers resolve overrides the same way they do in production.
    Process.put(:gen_controllers_spec, multi_resource_spec)

    %{
      spec: minimal_spec,
      crud_spec: crud_spec,
      multi_resource_spec: multi_resource_spec
    }
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

  # ── singularize/1 ────────────────────────────────────────────────────

  describe "singularize/1" do
    test "ies → y rule" do
      assert Controllers.singularize("categories") == "category"
      assert Controllers.singularize("entries") == "entry"
      assert Controllers.singularize("properties") == "property"
      assert Controllers.singularize("inventory_categories") == "inventory_category"
    end

    test "trivial s trim" do
      assert Controllers.singularize("widgets") == "widget"
      assert Controllers.singularize("members") == "member"
      assert Controllers.singularize("invitations") == "invitation"
    end

    test "ses → s (e.g. classes)" do
      assert Controllers.singularize("classes") == "class"
      assert Controllers.singularize("lenses") == "lens"
    end

    test "passes already-singular and non-plural names through" do
      assert Controllers.singularize("health") == "health"
      assert Controllers.singularize("waitlist") == "waitlist"
      assert Controllers.singularize("inventory") == "inventory"
    end
  end

  # ── Tag extensions (x-context / x-resource) ──────────────────────────

  describe "tag extensions" do
    test "tag_definition/2 returns the OpenApiSpex.Tag for a declared tag", %{
      multi_resource_spec: spec
    } do
      assert %OpenApiSpex.Tag{name: "InventoryCategories"} =
               Controllers.tag_definition(spec, "InventoryCategories")

      assert Controllers.tag_definition(spec, "DoesNotExist") == nil
    end

    test "tag_extension/2 reads x-context and x-resource from the stashed spec" do
      # The setup callback stashes the multi-resource spec.
      assert Controllers.tag_extension("InventoryCategories", "x-context") == "Dhc.Inventory"

      assert Controllers.tag_extension("InventoryCategories", "x-resource") ==
               "EquipmentCategory"

      assert Controllers.tag_extension("InventoryContainers", "x-resource") == "Container"
    end

    test "tag_extension/2 returns nil when the tag declares no extension", %{
      crud_spec: spec
    } do
      Process.put(:gen_controllers_spec, spec)

      assert Controllers.tag_extension("Widgets", "x-context") == nil
      assert Controllers.tag_extension("Widgets", "x-resource") == nil
    end

    test "tag_extension/2 returns nil when no spec is stashed" do
      Process.delete(:gen_controllers_spec)

      assert Controllers.tag_extension("InventoryCategories", "x-context") == nil
    after
      # Restore for subsequent tests — the setup block re-stashes, but be
      # defensive so test ordering never matters.
      Process.put(:gen_controllers_spec, parse_fixture!(@multi_resource_fixture))
    end
  end

  # ── Naming helpers with x-context / x-resource overrides ─────────────
  #
  # These exercise the private helpers via the public `tag_extension/2`
  # path. Because the helpers are private, we call them indirectly through
  # `controller_module/1`-equivalent public surface where possible and
  # assert on the generated controller content otherwise.

  describe "x-context / x-resource override resolution" do
    test "controller_module uses the tag name (not x-context) — only the alias changes" do
      # The controller module is always derived from the tag, so multiple
      # resources under one context get distinct controllers.
      assert Controllers.controller_module("InventoryCategories") ==
               "DhcWeb.InventoryCategoriesController"

      assert Controllers.controller_module("InventoryContainers") ==
               "DhcWeb.InventoryContainersController"
    end

    test "generated controller aliases the x-context module, not Dhc.<Tag>", %{
      multi_resource_spec: spec
    } do
      # Run the private content builder by invoking the public task entry
      # point indirectly: `controller_content/3` is private, so drive the
      # whole pipeline and read the generated controller text from disk
      # via the task's own file path.
      tag = "InventoryCategories"
      operations = Controllers.operations_for_tag(spec, tag)
      assert Enum.any?(operations, &(&1.operation_id == "inventoryCategories.create"))

      # The generated controller must `alias Dhc.Inventory` (x-context),
      # NOT `alias Dhc.InventoryCategories` (derived).
      content = controller_module_text!(spec, tag)

      assert content =~ ~S|alias Dhc.Inventory|
      refute content =~ ~S|alias Dhc.InventoryCategories|

      # The context function calls use the singularized resource name
      # (`inventory_category` from x-resource `EquipmentCategory`), not
      # the broken `inventory_categorie` the old `s`-trim produced.
      assert content =~ "list_equipment_categories()"
      assert content =~ "create_equipment_category("
      assert content =~ "get_equipment_category!(id)"

      # The struct reference in the changeset/JSON path must point at
      # `Dhc.Inventory.EquipmentCategory`.
      assert content =~ "Dhc.Inventory.EquipmentCategory"
      # Word-boundary so the legitimate module name `InventoryCategories`
      # (which contains `InventoryCategorie` as a substring) does not match.
      refute content =~ ~r/\bInventoryCategorie\b/
    end

    test "generated JSON renderer structs ref the x-context schema module", %{
      multi_resource_spec: spec
    } do
      content = json_renderer_module_text!(spec, "InventoryCategories")

      assert content =~ "Dhc.Inventory.EquipmentCategory"
      # Word-boundary so the legitimate module name `InventoryCategories`
      # (which contains `InventoryCategorie` as a substring) does not match.
      refute content =~ ~r/\bInventoryCategorie\b/
      refute content =~ "InventoryCategorys"
    end

    test "tags without x-context fall back to Dhc.<Tag> (backward compatible)", %{
      crud_spec: spec
    } do
      Process.put(:gen_controllers_spec, spec)

      content = controller_module_text!(spec, "Widgets")

      assert content =~ ~S|alias Dhc.Widgets|
      # `widgets` → `widget` (singularize trivial s-trim, unchanged).
      assert content =~ "list_widgets()"
      assert content =~ "create_widget("
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

  # Drives the public content builders (exposed as `@doc false`) to produce
  # the same controller/JSON module text that `run/1` would write to disk.
  # We stash `spec` into the process dictionary so the private naming helpers
  # that call `tag_extension/2` resolve overrides exactly as in production.
  defp controller_module_text!(spec, tag) do
    Process.put(:gen_controllers_spec, spec)
    module_name = Controllers.controller_module(tag)
    Controllers.controller_content(module_name, tag, spec)
  end

  defp json_renderer_module_text!(spec, tag) do
    Process.put(:gen_controllers_spec, spec)
    module_name = Controllers.json_module(tag)
    Controllers.json_renderer_content(module_name, tag, spec)
  end
end
