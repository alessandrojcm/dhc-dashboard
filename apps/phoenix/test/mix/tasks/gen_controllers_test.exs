defmodule Mix.Tasks.Gen.ControllersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Gen.Controllers

  @minimal_fixture "test/fixtures/minimal_spec.yaml"
  @crud_fixture "test/fixtures/crud_spec.yaml"
  @multi_resource_fixture "test/fixtures/multi_resource_spec.yaml"
  @multi_slice_fixture "test/fixtures/multi_slice_spec.yaml"
  @ref_param_fixture "test/fixtures/ref_param_spec.yaml"

  setup do
    minimal_spec = parse_fixture!(@minimal_fixture)
    crud_spec = parse_fixture!(@crud_fixture)
    multi_resource_spec = parse_fixture!(@multi_resource_fixture)
    multi_slice_spec = parse_fixture!(@multi_slice_fixture)
    ref_param_spec = parse_fixture!(@ref_param_fixture)

    # `tag_extension/2` reads the stashed spec from the process dictionary,
    # exactly as `run/1` does. Stash each spec under test so the private
    # naming helpers resolve overrides the same way they do in production.
    Process.put(:gen_controllers_spec, multi_resource_spec)

    %{
      spec: minimal_spec,
      crud_spec: crud_spec,
      multi_resource_spec: multi_resource_spec,
      multi_slice_spec: multi_slice_spec,
      ref_param_spec: ref_param_spec
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

    assert [_, _] = operations

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

    assert [_, _, _, _, _, _] = operations

    action_names =
      operations
      |> Enum.map(&Controllers.operation_id_to_action(&1.operation_id))
      |> Enum.sort()

    assert action_names == ["create", "delete", "index", "renew", "show", "update"]
  end

  test "operations_for_tag returns list-only operations for Gadgets", %{crud_spec: spec} do
    operations = Controllers.operations_for_tag(spec, "Gadgets")

    assert [_operation] = operations
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

  # ── Slices (operationId prefix → scaffolding unit) ───────────────────
  #
  # The generator's scaffolding unit is the *slice*, not the tag. A slice is
  # named by the `operationId` prefix (`inventoryStructure.showDefinition` →
  # `inventoryStructure`), which is what actually maps 1:1 onto a controller
  # file. This lets one domain keep one tag and one URL root while being
  # served by more than one controller.

  describe "operation_id_to_slice/1" do
    test "extracts the slice prefix from a dotted operationId" do
      assert Controllers.operation_id_to_slice("inventoryStructure.showDefinition") ==
               "inventoryStructure"

      assert Controllers.operation_id_to_slice("inventoryOperatorItems.list") ==
               "inventoryOperatorItems"

      assert Controllers.operation_id_to_slice("members.index") == "members"
    end

    test "returns nil when the operationId carries no slice prefix" do
      assert Controllers.operation_id_to_slice("legacyThings") == nil
      assert Controllers.operation_id_to_slice(nil) == nil
    end
  end

  describe "unique_slices/1" do
    test "splits a single tag into one slice per operationId prefix", %{
      multi_slice_spec: spec
    } do
      slices = Controllers.unique_slices(spec)
      names = Enum.map(slices, & &1.name) |> Enum.sort()

      # `Inventory` yields two slices; it must NOT yield an "Inventory" slice.
      assert "inventoryOperatorItems" in names
      assert "inventoryStructure" in names
      refute "Inventory" in names
    end

    test "each slice carries its owning tag so x-context still resolves", %{
      multi_slice_spec: spec
    } do
      slices = Controllers.unique_slices(spec)
      structure = Enum.find(slices, &(&1.name == "inventoryStructure"))

      assert structure.tag == "Inventory"
    end

    test "groups only that slice's operations, not the whole tag's", %{
      multi_slice_spec: spec
    } do
      slices = Controllers.unique_slices(spec)

      structure = Enum.find(slices, &(&1.name == "inventoryStructure"))
      items = Enum.find(slices, &(&1.name == "inventoryOperatorItems"))

      structure_ids = Enum.map(structure.operations, & &1.operation_id) |> Enum.sort()
      items_ids = Enum.map(items.operations, & &1.operation_id) |> Enum.sort()

      assert structure_ids == [
               "inventoryStructure.retireDefinition",
               "inventoryStructure.showDefinition"
             ]

      assert items_ids == [
               "inventoryOperatorItems.create",
               "inventoryOperatorItems.list"
             ]
    end

    test "falls back to the tag name when an operationId has no prefix", %{
      multi_slice_spec: spec
    } do
      slices = Controllers.unique_slices(spec)
      legacy = Enum.find(slices, &(&1.name == "Legacy"))

      assert legacy
      assert legacy.tag == "Legacy"
      assert Enum.map(legacy.operations, & &1.operation_id) == ["legacyThings"]
    end

    test "a tag whose ops all share one prefix yields exactly one slice", %{
      multi_resource_spec: spec
    } do
      slices = Controllers.unique_slices(spec)
      names = Enum.map(slices, & &1.name) |> Enum.sort()

      assert names == ["inventoryCategories", "inventoryContainers"]
    end

    test "slices are sorted by name for deterministic output", %{multi_slice_spec: spec} do
      names = Controllers.unique_slices(spec) |> Enum.map(& &1.name)

      assert names == Enum.sort(names)
    end
  end

  # ── Slice-derived file paths and module names ────────────────────────

  describe "slice-derived naming" do
    test "controller module and file come from the slice, not the tag", %{
      multi_slice_spec: spec
    } do
      slices = Controllers.unique_slices(spec)
      structure = Enum.find(slices, &(&1.name == "inventoryStructure"))
      items = Enum.find(slices, &(&1.name == "inventoryOperatorItems"))

      assert Controllers.controller_module(structure.name) ==
               "DhcWeb.InventoryStructureController"

      assert Controllers.controller_module(items.name) ==
               "DhcWeb.InventoryOperatorItemsController"

      assert Controllers.controller_file_path(structure.name) ==
               "lib/dhc_web/controllers/inventory_structure_controller.ex"

      assert Controllers.controller_file_path(items.name) ==
               "lib/dhc_web/controllers/inventory_operator_items_controller.ex"
    end

    test "json module and file come from the slice", %{multi_slice_spec: spec} do
      slices = Controllers.unique_slices(spec)
      items = Enum.find(slices, &(&1.name == "inventoryOperatorItems"))

      assert Controllers.json_module(items.name) == "DhcWeb.InventoryOperatorItemsJSON"

      assert Controllers.json_file_path(items.name) ==
               "lib/dhc_web/controllers/inventory_operator_items_json.ex"
    end

    test "no slice derives the bare tag-named controller path", %{multi_slice_spec: spec} do
      paths =
        spec
        |> Controllers.unique_slices()
        |> Enum.map(&Controllers.controller_file_path(&1.name))

      refute "lib/dhc_web/controllers/inventory_controller.ex" in paths
    end
  end

  # ── Scaffolding trio is one all-or-nothing unit ──────────────────────
  #
  # A slice's controller, JSON renderer and contract test are scaffolded
  # together or not at all. Once the controller exists the slice is
  # hand-owned, so re-running the generator must not reintroduce a renderer
  # or test for it — that is what used to resurrect `membership_json.ex`
  # and `onboarding_json.ex` against structs that do not exist.

  describe "scaffold_slice?/3" do
    test "scaffolds when the slice has no controller yet" do
      in_tmp_project(fn root ->
        assert Controllers.scaffold_slice?("brandNew", %{force: false}, root)
      end)
    end

    test "skips the whole trio when the controller already exists" do
      in_tmp_project(fn root ->
        write_controller!(root, "membership")

        refute Controllers.scaffold_slice?("membership", %{force: false}, root)
      end)
    end

    test "skips even when the renderer and test are absent" do
      in_tmp_project(fn root ->
        write_controller!(root, "membership")

        # Only the controller is on disk. The renderer/test must still be
        # skipped, because the slice is hand-owned. This is the regression
        # that used to resurrect `membership_json.ex` on every api-gen run.
        refute File.exists?(Path.join(root, "lib/dhc_web/controllers/membership_json.ex"))

        refute File.exists?(
                 Path.join(root, "test/dhc_web/controllers/membership_controller_test.exs")
               )

        refute Controllers.scaffold_slice?("membership", %{force: false}, root)
      end)
    end

    test "--force overrides the skip" do
      in_tmp_project(fn root ->
        write_controller!(root, "membership")

        assert Controllers.scaffold_slice?("membership", %{force: :all}, root)
      end)
    end

    test "--force=<path> overrides the skip for that slice's controller" do
      in_tmp_project(fn root ->
        write_controller!(root, "membership")
        path = "lib/dhc_web/controllers/membership_controller.ex"

        assert Controllers.scaffold_slice?("membership", %{force: path}, root)

        refute Controllers.scaffold_slice?(
                 "membership",
                 %{force: "lib/other_controller.ex"},
                 root
               )
      end)
    end
  end

  # ── `$ref` path parameters ───────────────────────────────────────────
  #
  # A path may declare its parameters as `- $ref: "#/components/parameters/X"`
  # instead of inline. OpenApiSpex decodes those to `%OpenApiSpex.Reference{}`,
  # which carries only a `"$ref":` field — so the generator has to dereference
  # against `spec.components.parameters` before it can read `.in` / `.name`,
  # exactly as it already does for schema refs.

  describe "$ref path parameters" do
    test "the fixture really decodes its path parameters as references", %{
      ref_param_spec: spec
    } do
      assert [%OpenApiSpex.Reference{"$ref": "#/components/parameters/SlugOrId"}] =
               spec.paths["/refs/{slugOrId}"].get.parameters
    end

    test "the fixture's slice is one the generator would actually write", %{
      ref_param_spec: spec
    } do
      # The bug hid behind the skip: every slice in the real spec already has a
      # hand-written controller, so `controller_content/3` never ran for it.
      # This fixture is only a regression test while its slice stays
      # unscaffolded — assert that rather than trusting a comment.
      assert [%{name: "refs"}] = Controllers.unique_slices(spec)
      assert Controllers.scaffold_slice?("refs", %{force: false})
      refute File.exists?(Path.join(File.cwd!(), Controllers.controller_file_path("refs")))
    end

    test "action signatures bind the referenced parameter name", %{ref_param_spec: spec} do
      content = controller_module_text!(spec, "Refs")

      assert content =~ ~S|def show(conn, %{"slugOrId" => id})|
      assert content =~ ~S|def update(conn, %{"slugOrId" => id} = params)|
      assert content =~ ~S|def delete(conn, %{"slugOrId" => id})|
      assert content =~ ~S|def archive(conn, %{"slugOrId" => id}|

      # The `|| "id"` fallback must not swallow a resolvable ref.
      refute content =~ ~S|%{"id" => id}|
    end

    test "contract test paths substitute the referenced parameter", %{ref_param_spec: spec} do
      content = contract_test_text!(spec, "Refs")

      assert content =~ ~S|get(conn, "/api/refs/1")|
      assert content =~ ~S|patch(conn, "/api/refs/1", %{})|
      assert content =~ ~S|delete(conn, "/api/refs/1")|
      assert content =~ ~S|post(conn, "/api/refs/1/archive")|

      # `{slugOrId}` may still appear in a test *name* (which quotes the raw
      # `op.path` as documentation), but never in a request path.
      refute content =~ ~r/conn, "[^"]*\{slugOrId\}/
    end

    test "an unresolvable parameter ref is dropped rather than crashing", %{
      ref_param_spec: spec
    } do
      # A spec whose component parameters were stripped (or a dangling ref)
      # must degrade to the `id` default instead of raising.
      stripped = put_in(spec.components.parameters, nil)

      content = controller_module_text!(stripped, "Refs")

      assert content =~ ~S|def show(conn, %{"id" => id})|
      assert contract_test_text!(stripped, "Refs") =~ ~S|get(conn, "/api/refs/{slugOrId}")|
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Creates a throwaway directory that looks enough like the Phoenix app for
  # the generator's existence checks to run against it. The root is passed
  # explicitly (never via `File.cd!/1`, which is VM-global and would race
  # with `async: true` tests).
  defp in_tmp_project(fun) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "gen_controllers_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "lib/dhc_web/controllers"))
    File.mkdir_p!(Path.join(tmp, "test/dhc_web/controllers"))

    try do
      fun.(tmp)
    after
      File.rm_rf!(tmp)
    end
  end

  defp write_controller!(root, slice) do
    File.write!(
      Path.join(root, "lib/dhc_web/controllers/#{slice}_controller.ex"),
      "defmodule Stub do\nend\n"
    )
  end

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
    slice = slice_for_tag!(spec, tag)
    Controllers.controller_content(Controllers.controller_module(slice.name), slice, spec)
  end

  defp json_renderer_module_text!(spec, tag) do
    Process.put(:gen_controllers_spec, spec)
    slice = slice_for_tag!(spec, tag)
    Controllers.json_renderer_content(Controllers.json_module(slice.name), slice, spec)
  end

  defp contract_test_text!(spec, tag) do
    Process.put(:gen_controllers_spec, spec)
    Controllers.contract_test_content(slice_for_tag!(spec, tag), spec)
  end

  # The single slice owned by `tag`. Used by the naming tests, which predate
  # slices and assert on tags that map to exactly one slice.
  defp slice_for_tag!(spec, tag) do
    case Enum.filter(Controllers.unique_slices(spec), &(&1.tag == tag)) do
      [slice] ->
        slice

      slices ->
        raise "expected exactly one slice for tag #{tag}, got: " <>
                inspect(Enum.map(slices, & &1.name))
    end
  end
end
