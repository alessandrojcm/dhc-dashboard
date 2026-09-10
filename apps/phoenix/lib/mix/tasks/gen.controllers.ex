defmodule Mix.Tasks.Gen.Controllers do
  @moduledoc """
  Generates Phoenix controllers, JSON renderers, and contract tests from an OpenAPI spec.

  Reads `priv/api/openapi.yaml` and emits one controller, one JSON
  renderer, and one test file per **slice** found in the spec's operations.

  ## Slices vs tags

  A *slice* is the scaffolding unit and is named by the `operationId` prefix
  (`inventoryStructure.showDefinition` → slice `inventoryStructure` →
  `inventory_structure_controller.ex`).

  The *tag* remains the domain boundary — "one domain = one tag = one URL
  root" — and supplies the `x-context` / `x-resource` extensions. Because a
  domain may be served by several controllers, one tag may contain several
  slices: the `Inventory` tag holds both `inventoryStructure` and
  `inventoryOperatorItems`. Keying scaffolding on the slice is what keeps
  `mix gen.controllers` idempotent for such tags.

  ## Usage

      mix gen.controllers              # generate from priv/api/openapi.yaml
      mix gen.controllers --force      # overwrite all existing files
      mix gen.controllers --force=<path> # overwrite a specific slice's files

  ## Output

  For each unique slice found (e.g. `widgets`), the task generates:

    - `lib/dhc_web/controllers/<slice>_controller.ex`
    - `lib/dhc_web/controllers/<slice>_json.ex`
    - `test/dhc_web/controllers/<slice>_controller_test.exs`
    - A router entry printed to the console

  The three files are one all-or-nothing unit: if the slice's controller
  already exists the slice is considered hand-owned and none of the three is
  written. Pass `--force` to overwrite all, or
  `--force=lib/dhc_web/controllers/foo_controller.ex` to overwrite one slice.

  ## OpenAPI Conventions

  - Each operation **must** be tagged with exactly one tag.
  - The `operationId` **should** be `<slice>.<action>`; the slice names the
    controller. E.g. `widgets.index` produces `DhcWeb.WidgetsController`.
    An operationId with no prefix falls back to the tag name as its slice.
  - REST action names are derived from HTTP method + path pattern:
    `GET /resources` → `index`, `GET /resources/{id}` → `show`,
    `POST /resources` → `create`, `PUT|PATCH /resources/{id}` → `update`,
    `DELETE /resources/{id}` → `delete`.
  - Non-REST paths derive the action name from the last non-parameter
    path segment (e.g. `POST /resources/{id}/renew` → `renew`).
  - If an `operationId` is present, its action portion is used as fallback
    for non-standard paths.
  """

  use Mix.Task

  @shortdoc "Generate controllers, JSON renderers, and contract tests from an OpenAPI spec"

  @spec_file "priv/api/openapi.yaml"
  @controller_dir "lib/dhc_web/controllers"
  @test_dir "test/dhc_web/controllers"

  @http_verbs [:get, :post, :put, :patch, :delete]

  @doc false
  def run(args) do
    opts = parse_args(args)
    spec = parse_spec!(@spec_file)

    # Stash the spec so the naming helpers (context_module/1,
    # resource_singular/1, …) can resolve `x-context` / `x-resource` tag
    # extensions without threading `spec` through every call site.
    Process.put(:gen_controllers_spec, spec)

    slices = unique_slices(spec)

    if Enum.empty?(slices) do
      Mix.shell().info("No tagged operations found in #{@spec_file}.")
    else
      Mix.shell().info("Found slices: #{Enum.map_join(slices, ", ", & &1.name)}")

      Enum.each(slices, &generate_slice(&1, spec, opts))

      print_router_entries(slices)
    end
  end

  # ── Argument parsing ─────────────────────────────────────────────────

  @doc false
  def parse_args(args) do
    # Manually check for --force=<path> before OptionParser consumes it
    force_with_path =
      Enum.find_value(args, fn
        "--force=" <> path -> path
        _ -> nil
      end)

    {opts, _remaining, _} =
      OptionParser.parse(args, strict: [force: :boolean])

    force =
      cond do
        force_with_path -> force_with_path
        Keyword.get(opts, :force, false) -> :all
        true -> false
      end

    %{force: force}
  end

  # ── Spec parsing ──────────────────────────────────────────────────────

  defp parse_spec!(path) do
    unless File.exists?(path) do
      Mix.raise("Spec file not found: #{path}")
    end

    raw_map =
      case YamlElixir.read_from_string(File.read!(path)) do
        {:ok, spec} -> spec
        {:error, error} -> Mix.raise("Failed to parse #{path}: #{inspect(error)}")
      end

    try do
      OpenApiSpex.OpenApi.Decode.decode(raw_map)
    rescue
      e in KeyError ->
        Mix.raise("Failed to decode spec: #{Exception.message(e)}")
    end
  end

  # ── Operation discovery ──────────────────────────────────────────────

  @doc """
  Returns unique, sorted tags from all operations in the spec.
  """
  def unique_tags(spec) do
    spec.paths
    |> Enum.flat_map(fn {_path, path_item} ->
      Enum.flat_map(@http_verbs, &operation_tags(path_item, &1))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Extracts operations matching the given tag.
  Returns a list of `%{method: atom, path: String.t(), operation_id: String.t(), operation: Operation.t()}`.
  """
  def operations_for_tag(spec, tag) do
    spec.paths
    |> Enum.flat_map(fn {path, path_item} ->
      @http_verbs
      |> Enum.filter(&operation_tagged?(path_item, &1, tag))
      |> Enum.map(fn verb ->
        %OpenApiSpex.Operation{} = operation = Map.get(path_item, verb)

        %{
          method: verb,
          path: path,
          operation_id: operation.operationId,
          operation: operation
        }
      end)
    end)
  end

  defp operation_tags(path_item, verb) do
    case Map.get(path_item, verb) do
      %OpenApiSpex.Operation{tags: tags} when is_list(tags) -> tags
      _ -> []
    end
  end

  defp operation_tagged?(path_item, verb, tag) do
    case Map.get(path_item, verb) do
      %OpenApiSpex.Operation{tags: tags} -> tag in (tags || [])
      _ -> false
    end
  end

  # ── Slice discovery ──────────────────────────────────────────────────
  #
  # A *slice* is the generator's scaffolding unit: one controller, one JSON
  # renderer, one contract test. It is named by the `operationId` prefix
  # (`inventoryStructure.showDefinition` → `inventoryStructure`), because
  # that is what maps 1:1 onto a controller file.
  #
  # The tag remains the *domain* boundary ("one domain = one tag = one URL
  # root"). Keying scaffolding on the slice lets one domain be served by
  # more than one controller without the generator re-emitting a broken
  # stub for a tag-named controller that intentionally does not exist.
  #
  # Each slice keeps its owning `tag` so the `x-context` / `x-resource` tag
  # extensions continue to resolve context and resource names.

  @doc """
  Returns the slices in the spec, sorted by name.

  Each slice is a map of `%{name: String.t(), tag: String.t(), operations: [map]}`.
  Operations whose `operationId` has no `<slice>.<action>` prefix fall back to
  their tag name as the slice name, preserving the historical one-per-tag
  behaviour for specs that do not use prefixed operationIds.
  """
  def unique_slices(spec) do
    spec
    |> unique_tags()
    |> Enum.flat_map(fn tag ->
      spec
      |> operations_for_tag(tag)
      |> Enum.group_by(&slice_name_for(&1, tag))
      |> Enum.map(fn {slice_name, operations} ->
        %{name: slice_name, tag: tag, operations: operations}
      end)
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp slice_name_for(op, tag) do
    operation_id_to_slice(op.operation_id) || tag
  end

  @doc """
  Derives the slice name from an operationId.

  The operationId is expected in the form `<slice>.<action>` (e.g.
  `inventoryStructure.showDefinition` → `inventoryStructure`). Returns `nil`
  when the operationId is absent or carries no prefix.
  """
  def operation_id_to_slice(operation_id) when is_binary(operation_id) do
    case String.split(operation_id, ".", parts: 2) do
      [slice, _action] -> slice
      _ -> nil
    end
  end

  def operation_id_to_slice(_operation_id), do: nil

  # ── File generation ──────────────────────────────────────────────────

  # The controller, JSON renderer and contract test form one all-or-nothing
  # scaffolding unit. Once a slice's controller exists the slice is
  # hand-owned, so none of the three is re-emitted. Checking each file
  # independently used to resurrect renderers for slices that deliberately
  # render through another module (e.g. `membership_json.ex` against the
  # non-existent `%Dhc.Membership.Membership{}`).
  defp generate_slice(slice, spec, opts) do
    controller_path = controller_file_path(slice.name)

    if scaffold_slice?(slice.name, opts) do
      write_file!(controller_path, controller_content(controller_module(slice.name), slice, spec))
      Mix.shell().info([:green, "  create ", :reset, controller_path])

      json_path = json_file_path(slice.name)
      write_file!(json_path, json_renderer_content(json_module(slice.name), slice, spec))
      Mix.shell().info([:green, "  create ", :reset, json_path])

      test_path = contract_test_file_path(slice.name)
      write_file!(test_path, contract_test_content(slice, spec))
      Mix.shell().info([:green, "  create ", :reset, test_path])
    else
      Mix.shell().info([
        :yellow,
        "  skip ",
        :reset,
        "#{slice.name} (#{controller_path} already exists)"
      ])
    end
  end

  @doc """
  Returns true when a slice should be scaffolded.

  A slice is scaffolded only when its controller does not yet exist, or when
  `--force` / `--force=<controller path>` was passed. The controller's
  presence is the single signal that the slice is hand-owned, so its JSON
  renderer and contract test are governed by the same answer.

  `root` defaults to the current working directory; it is passed explicitly
  in tests.
  """
  def scaffold_slice?(slice_name, opts, root \\ nil) do
    root = root || File.cwd!()
    controller_path = controller_file_path(slice_name)

    if File.exists?(Path.join(root, controller_path)) do
      case opts[:force] do
        :all -> true
        ^controller_path -> true
        _ -> false
      end
    else
      true
    end
  end

  defp write_file!(file_path, content) do
    full_path = Path.join(File.cwd!(), file_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  # ── Controller module content ────────────────────────────────────────

  @doc false
  def controller_content(module_name, slice, spec) do
    %{tag: tag, operations: operations} = slice
    aliases = controller_aliases(operations, spec, tag)
    action_defs = Enum.map(operations, &controller_action(&1, tag, spec))

    action_defs =
      if Enum.empty?(action_defs) do
        ""
      else
        Enum.join(action_defs, "\n") |> String.trim_trailing()
      end

    """
    defmodule #{module_name} do
      use DhcWeb, :controller

      alias #{context_module(tag)}
    #{aliases}
    #{action_defs}
    end
    """
  end

  defp controller_aliases(operations, spec, tag) do
    struct_modules =
      operations
      |> Enum.flat_map(fn op ->
        case response_schema(op, spec) do
          %OpenApiSpex.Schema{properties: %{data: %OpenApiSpex.Schema{items: items}}} ->
            [schema_module_name(items, tag)]

          %OpenApiSpex.Schema{properties: %{data: data_schema}} ->
            [schema_module_name(data_schema, tag)]

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    case struct_modules do
      [] -> ""
      modules -> "\n  alias #{Enum.join(modules, "\n  alias ")}"
    end
  end

  defp schema_module_name(%OpenApiSpex.Reference{"$ref": "#/components/schemas/" <> name}, tag) do
    # Prefer the tag-derived context (`x-context` override or `Dhc.<Tag>`)
    # so a spec whose response schema is named e.g. `InventoryCategory`
    # still resolves to `Dhc.Inventory.EquipmentCategory` when the tag
    # declares `x-context: Dhc.Inventory` / `x-resource: EquipmentCategory`.
    # Fall back to the schema-name-derived context only when the tag has
    # no override (preserves the historical `Widget` → `Dhc.Widgets.Widget`
    # behavior for tags that match their schema name).
    if tag_extension(tag, "x-context") || tag_extension(tag, "x-resource") do
      "#{context_module(tag)}.#{Macro.camelize(resource_singular(tag))}"
    else
      context_module_from_schema(name)
    end
  end

  defp schema_module_name(_schema, tag) do
    # Fallback: derive from tag
    "#{context_module(tag)}.#{Macro.camelize(resource_singular(tag))}"
  end

  defp context_module_from_schema(schema_name) do
    # Derive context module from schema name: "Widget" → "Dhc.Widgets.Widget"
    # Find the plural form by adding "s" to the schema name
    plural = "#{Macro.camelize(schema_name)}s"
    "Dhc.#{plural}.#{Macro.camelize(schema_name)}"
  end

  defp controller_action(op, tag, spec) do
    action = action_name(op)
    method_str = op.method |> to_string() |> String.upcase()
    r_singular = resource_singular(tag)
    r_var = resource_var(tag)
    r_plural = resource_plural(tag)
    ctx = short_context_module(tag)
    changeset = changeset_code(op, tag, spec)
    has_body = not is_nil(op.operation.requestBody)

    case action do
      # GET collection → index
      "index" ->
        """
          @doc \"\"\"
          #{method_str} #{op.path}
          \"\"\"
          def index(conn, _params) do
            #{r_plural} = #{ctx}.list_#{r_plural}()
            render(conn, :index, #{r_plural}: #{r_plural})
          end
        """

      # GET single → show
      "show" ->
        id_param = path_id_param_or_default(op, spec)

        """
          @doc \"\"\"
          #{method_str} #{op.path}
          \"\"\"
          def show(conn, %{"#{id_param}" => id}) do
            #{r_var} = #{ctx}.get_#{r_singular}!(id)
            render(conn, :show, #{r_var}: #{r_var})
          end
        """

      # POST collection → create
      "create" ->
        assigns = params_binding(has_body)

        """
          @doc \"\"\"
          #{method_str} #{op.path}
          \"\"\"
          def create(conn, #{assigns}) do
        #{changeset}
            with {:ok, #{r_var}} <- #{ctx}.create_#{r_singular}(changeset) do
              conn
              |> put_status(:created)
              |> render(:show, #{r_var}: #{r_var})
            end
          end
        """

      # DELETE single → delete
      "delete" ->
        id_param = path_id_param_or_default(op, spec)

        """
          @doc \"\"\"
          #{method_str} #{op.path}
          \"\"\"
          def delete(conn, %{"#{id_param}" => id}) do
            #{r_var} = #{ctx}.get_#{r_singular}!(id)

            with {:ok, #{r_var}} <- #{ctx}.delete_#{r_singular}(#{r_var}) do
              render(conn, :show, #{r_var}: #{r_var})
            end
          end
        """

      # PUT/PATCH single → update
      "update" ->
        id_param = path_id_param_or_default(op, spec)

        """
          @doc \"\"\"
          #{method_str} #{op.path}
          \"\"\"
          def update(conn, %{"#{id_param}" => id} = params) do
            #{r_var} = #{ctx}.get_#{r_singular}!(id)
        #{changeset}
            with {:ok, #{r_var}} <- #{ctx}.update_#{r_singular}(#{r_var}, changeset) do
              render(conn, :show, #{r_var}: #{r_var})
            end
          end
        """

      # Non-REST (e.g. POST /resources/{id}/renew → renew)
      _ ->
        id_param = path_id_param_or_default(op, spec)
        assigns = params_binding(has_body)

        """
          @doc \"\"\"
          #{method_str} #{op.path}
          \"\"\"
          def #{action}(conn, %{"#{id_param}" => id} = #{assigns}) do
            #{r_var} = #{ctx}.get_#{r_singular}!(id)
        #{changeset}
            with {:ok, #{r_var}} <- #{ctx}.#{action}_#{r_singular}(#{r_var}, changeset) do
              render(conn, :show, #{r_var}: #{r_var})
            end
          end
        """
    end
  end

  defp path_id_param_or_default(op, spec), do: path_id_param(op, spec) || "id"
  defp params_binding(true), do: "params"
  defp params_binding(false), do: "_params"

  # ── JSON renderer module content ─────────────────────────────────────

  @doc false
  def json_renderer_content(module_name, slice, spec) do
    %{tag: tag, operations: operations} = slice
    r_singular = resource_singular(tag)
    r_var = resource_var(tag)
    r_plural = resource_plural(tag)

    templates =
      operations
      |> Enum.map(fn op ->
        action = action_name(op)
        if action == "index", do: "index", else: "show"
      end)
      |> Enum.uniq()

    render_clauses =
      templates
      |> Enum.map(fn template ->
        if template == "index" do
          """
            def render("index.json", %{#{r_plural}: #{r_plural}}) do
              %{data: Enum.map(#{r_plural}, &render_#{r_singular}/1)}
            end
          """
        else
          """
            def render("show.json", %{#{r_var}: #{r_var}}) do
              %{data: render_#{r_singular}(#{r_var})}
            end
          """
        end
      end)

    render_clauses =
      if Enum.empty?(render_clauses) do
        ""
      else
        Enum.join(render_clauses, "\n")
      end

    # Emit render_<resource> helper with pattern match on the struct
    struct_module = context_module(tag) <> "." <> Macro.camelize(r_singular)
    fields = renderer_fields(slice, spec)

    """
    defmodule #{module_name} do
      @moduledoc false

    #{render_clauses}

      defp render_#{r_singular}(%#{struct_module}{} = #{r_var}) do
        %{
    #{fields}
        }
      end
    end
    """
  end

  defp renderer_fields(slice, spec) do
    # Find the first response schema that has a data property with fields
    %{tag: tag, operations: ops} = slice

    field_schema =
      Enum.find_value(ops, fn op ->
        case response_schema(op, spec) do
          %OpenApiSpex.Schema{properties: %{data: data_schema}} ->
            schema_properties(data_schema, spec)

          _ ->
            nil
        end
      end)

    case field_schema do
      nil ->
        "          # TODO: add fields from the response schema"

      fields ->
        r_var = resource_var(tag)

        max_len =
          fields
          |> Enum.map(&(elem(&1, 0) |> Atom.to_string() |> String.length()))
          |> Enum.max(fn -> 0 end)

        Enum.map_join(fields, ",\n", fn {name, _type} ->
          pad = String.duplicate(" ", max_len - String.length(Atom.to_string(name)))
          "          #{name}:#{pad} #{r_var}.#{name}"
        end)
    end
  end

  # ── Contract test content ────────────────────────────────────────────

  @doc false
  def contract_test_content(slice, spec) do
    module_name = controller_test_module(slice.name)
    test_cases = Enum.map(slice.operations, &contract_test_case(&1, spec))

    """
    defmodule #{module_name} do
      use DhcWeb.ConnCase, async: true

    #{Enum.join(test_cases, "\n")}
    end
    """
  end

  defp contract_test_case(op, spec) do
    action = action_name(op)
    method = op.method |> to_string() |> String.upcase()
    status_code = expected_status(op)
    phx_path = contract_test_path(op, spec)
    http_method = op.method |> to_string() |> String.downcase()

    body =
      if op.operation.requestBody != nil do
        """
            conn = #{http_method}(conn, "#{phx_path}", %{})
            assert json_response(conn, #{status_code})
            assert %{"data" => _} = json_response(conn, #{status_code})
        """
      else
        """
            conn = #{http_method}(conn, "#{phx_path}")
            assert json_response(conn, #{status_code})
            assert %{"data" => _} = json_response(conn, #{status_code})
        """
      end

    """
      describe "#{action}" do
        test "returns #{status_code} #{method} #{op.path}", %{conn: conn} do
    #{body}    end
      end
    """
  end

  defp expected_status(op) do
    # Find the lowest success status code from the responses
    success_status =
      op.operation.responses
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "2"))
      |> Enum.map(&String.to_integer/1)
      |> Enum.min(fn -> 299 end)

    success_status || 200
  end

  # ── Router entries ───────────────────────────────────────────────────

  defp print_router_entries(slices) do
    Mix.shell().info("\n── Router entries (paste into lib/dhc_web/router.ex) ──")

    Enum.each(slices, fn slice ->
      short_ctrl = String.split(controller_module(slice.name), ".") |> List.last()

      Enum.each(slice.operations, fn op ->
        action = action_name(op)

        route =
          "#{op.method} \"#{op.path}\", #{short_ctrl}, :#{action}"

        Mix.shell().info("  #{route}")
      end)
    end)

    Mix.shell().info("── end router entries ──")
  end

  # ── Naming helpers ───────────────────────────────────────────────────

  @doc """
  Derives the full controller module name from a tag.
  """
  def controller_module(tag), do: "DhcWeb.#{Macro.camelize(tag)}Controller"

  @doc """
  Derives the full JSON renderer module name from a tag.
  """
  def json_module(tag), do: "DhcWeb.#{Macro.camelize(tag)}JSON"

  defp controller_test_module(tag), do: "DhcWeb.#{Macro.camelize(tag)}ControllerTest"

  @doc """
  Derives the action (function) name from an operationId.

  The operationId is expected in the form `<tag>.<action>` (e.g. `health.index`).
  Returns the action name as a string (e.g. `"index"`).
  """
  def operation_id_to_action(operation_id) when is_binary(operation_id) do
    case String.split(operation_id, ".", parts: 2) do
      [_tag, action] -> action
      _ -> operation_id
    end
  end

  @doc """
  Derives the action name from HTTP method and path pattern.

  Standard REST mappings:
    - GET /resources → index
    - GET /resources/{id} → show
    - POST /resources → create
    - PUT|PATCH /resources/{id} → update
    - DELETE /resources/{id} → delete

  Non-REST paths (e.g. POST /resources/{id}/renew) derive from
  the last non-parameter path segment.
  """
  def action_from_http(method, path) when method in @http_verbs do
    segments = String.split(path, "/", trim: true)
    params = Enum.filter(segments, &param_segment?/1)
    has_trailing_param = segments != [] and param_segment?(List.last(segments))
    shape = path_shape(params, has_trailing_param)

    standard_action(method, shape) || custom_action(segments)
  end

  defp path_shape([], _has_trailing_param), do: :collection
  defp path_shape([_], true), do: :member
  defp path_shape(_params, _has_trailing_param), do: :custom

  defp standard_action(:get, :collection), do: "index"
  defp standard_action(:get, :member), do: "show"
  defp standard_action(:post, :collection), do: "create"
  defp standard_action(method, :member) when method in [:put, :patch], do: "update"
  defp standard_action(:delete, :member), do: "delete"
  defp standard_action(_method, _shape), do: nil

  defp custom_action(segments) do
    segments
    |> Enum.reject(&param_segment?/1)
    |> List.last()
    |> Kernel.||("action")
  end

  # ── Tag extensions ───────────────────────────────────────────────────
  #
  # The spec may declare a top-level `tags:` array with vendor extensions
  # that override the derived context/resource names for a tag:
  #
  #     tags:
  #       - name: InventoryCategories
  #         x-context: Dhc.Inventory          # → context module
  #         x-resource: EquipmentCategory      # → singular schema module
  #
  # Without `x-context`, the context is derived from the tag
  # (`Dhc.InventoryCategories`). Without `x-resource`, the singular is
  # derived via `singularize/1` (`inventory_categories` → `inventory_category`).
  #
  # This lets one Phoenix context own multiple OpenAPI tags (e.g. an
  # `Inventory` capability owning `InventoryCategories`, `InventoryContainers`,
  # `InventoryItems`) without hand-editing the generated controller aliases.

  @doc """
  Returns the `%OpenApiSpex.Tag{}` for the given tag name, or `nil`.
  Exposed for testing.
  """
  def tag_definition(spec, tag) do
    case spec.tags do
      nil -> nil
      tags -> Enum.find(tags, &(&1.name == tag))
    end
  end

  @doc """
  Reads an `x-*` extension from the tag definition in the stashed spec.
  Returns `nil` when the tag has no such extension (including when no
  top-level `tags:` array exists).
  """
  def tag_extension(tag, key) do
    case Process.get(:gen_controllers_spec) do
      nil ->
        nil

      spec ->
        case tag_definition(spec, tag) do
          nil -> nil
          %OpenApiSpex.Tag{extensions: ext} when is_map(ext) -> Map.get(ext, key)
          _ -> nil
        end
    end
  end

  # ── Context helpers ──────────────────────────────────────────────────

  defp context_module(tag) do
    case tag_extension(tag, "x-context") do
      nil -> "Dhc.#{Macro.camelize(tag)}"
      ctx -> ctx
    end
  end

  defp short_context_module(tag) do
    case tag_extension(tag, "x-context") do
      nil -> Macro.camelize(tag)
      ctx -> ctx |> String.split(".") |> List.last()
    end
  end

  # The singular schema module name (CamelCase), used for
  # `Dhc.<Context>.<Singular>` struct refs and context function names like
  # `list_<plural>/0`, `create_<singular>/1`.
  defp resource_singular(tag) do
    case tag_extension(tag, "x-resource") do
      nil ->
        tag |> Macro.underscore() |> singularize()

      resource ->
        resource |> Macro.underscore()
    end
  end

  defp resource_plural(tag) do
    resource_singular(tag) |> pluralize()
  end

  defp resource_var(tag) do
    resource_singular(tag)
  end

  @doc """
  Singularizes an underscored plural noun.

  Handles the common English inflections the generator's tags use:
  `categories` → `category`, `entries` → `entry`, `properties` → `property`
  (the `ies` → `y` rule), plus the trivial `s` trim for the rest
  (`widgets` → `widget`, `members` → `member`). Returns the input unchanged
  when it is not a recognizable plural, so already-singular names pass
  through.

  Exposed for testing.
  """
  def singularize(underscored) do
    cond do
      String.ends_with?(underscored, "ies") ->
        String.trim_trailing(underscored, "ies") <> "y"

      String.ends_with?(underscored, "ses") ->
        String.trim_trailing(underscored, "es")

      String.ends_with?(underscored, "s") ->
        String.trim_trailing(underscored, "s")

      true ->
        underscored
    end
  end

  @doc """
  Pluralizes an underscored singular noun.

  Inverse of `singularize/1`: `category` → `categories`, `entry` → `entries`
  (consonant + `y` → `ies`), otherwise appends `s` (`widget` → `widgets`).

  Exposed for testing.
  """
  def pluralize(underscored) do
    if Regex.match?(~r/[^aeiou]y$/, underscored) do
      String.replace(underscored, ~r/y$/, "ies")
    else
      underscored <> "s"
    end
  end

  # ── File path helpers ────────────────────────────────────────────────

  @doc """
  The controller path for a slice name. Exposed for testing.
  """
  def controller_file_path(slice_name) do
    Path.join(@controller_dir, "#{Macro.underscore(slice_name)}_controller.ex")
  end

  @doc """
  The JSON renderer path for a slice name. Exposed for testing.
  """
  def json_file_path(slice_name) do
    Path.join(@controller_dir, "#{Macro.underscore(slice_name)}_json.ex")
  end

  defp contract_test_file_path(slice_name) do
    Path.join(@test_dir, "#{Macro.underscore(slice_name)}_controller_test.exs")
  end

  # ── Action name resolution ───────────────────────────────────────────

  defp action_name(op) do
    derived = action_from_http(op.method, op.path)

    if op.operation_id do
      op_action = operation_id_to_action(op.operation_id)

      # If operationId specifies a standard REST action, prefer it over
      # the path-derived name (handles cases like GET /health/detailed
      # with operationId "health.show").
      preferred_action(op_action, derived)
    else
      derived
    end
  end

  defp preferred_action(op_action, _derived)
       when op_action in ~w(index show create update delete),
       do: op_action

  defp preferred_action(_op_action, derived) when derived in ~w(index show create update delete),
    do: derived

  defp preferred_action(op_action, _derived), do: op_action

  # ── Path analysis helpers ────────────────────────────────────────────

  defp param_segment?(segment) do
    String.starts_with?(segment, "{") and String.ends_with?(segment, "}")
  end

  defp path_id_param(op, spec) do
    op
    |> path_parameters(spec)
    |> case do
      [] -> nil
      [param | _rest] -> param.name
    end
  end

  defp contract_test_path(op, spec) do
    # Convert /widgets/{id} → /api/widgets/1 (with placeholder values for path params)
    path =
      op
      |> path_parameters(spec)
      |> Enum.reduce(op.path, fn param, acc ->
        String.replace(acc, "{#{param.name}}", "1")
      end)

    "/api" <> path
  end

  # The `in: :path` parameters of an operation, with any
  # `$ref: "#/components/parameters/X"` entries dereferenced first. A ref that
  # cannot be resolved is dropped rather than crashing the generator, so a
  # partial or dangling spec still scaffolds (falling back to the `id`
  # default and leaving the placeholder in the contract test path).
  defp path_parameters(op, spec) do
    (op.operation.parameters || [])
    |> Enum.map(&resolve_parameter(&1, spec))
    |> Enum.filter(&match?(%OpenApiSpex.Parameter{in: :path}, &1))
  end

  # ── Component reference helpers ──────────────────────────────────────

  defp resolve_parameter(parameter_or_ref, spec) do
    case parameter_or_ref do
      %OpenApiSpex.Reference{"$ref": "#/components/parameters/" <> name} ->
        component_parameters(spec)[name]

      other ->
        other
    end
  end

  defp component_parameters(%OpenApiSpex.OpenApi{components: %{parameters: params}})
       when is_map(params),
       do: params

  defp component_parameters(_spec), do: %{}

  # ── Schema helpers ───────────────────────────────────────────────────

  defp resolve_schema(schema_or_ref, spec) do
    case schema_or_ref do
      %OpenApiSpex.Reference{"$ref": "#/components/schemas/" <> name} ->
        spec.components.schemas[name]

      other ->
        other
    end
  end

  defp response_schema(op, spec) do
    success_status =
      op.operation.responses
      |> Map.keys()
      |> Enum.find(&String.starts_with?(&1, "2"))

    case success_status do
      nil ->
        nil

      status ->
        response = op.operation.responses[status]

        case response do
          %{content: %{"application/json" => %OpenApiSpex.MediaType{schema: schema}}} ->
            resolve_schema(schema, spec)

          _ ->
            nil
        end
    end
  end

  defp request_body_schema(op, spec) do
    case op.operation.requestBody do
      %OpenApiSpex.RequestBody{
        content: %{"application/json" => %OpenApiSpex.MediaType{schema: schema}}
      } ->
        resolve_schema(schema, spec)

      _ ->
        nil
    end
  end

  defp schema_properties(%OpenApiSpex.Reference{} = ref, spec) do
    resolved = resolve_schema(ref, spec)
    schema_properties(resolved, spec)
  end

  defp schema_properties(%OpenApiSpex.Schema{properties: props}, _spec) when is_map(props) do
    Enum.map(props, fn {name, prop_schema} ->
      type =
        case prop_schema do
          %OpenApiSpex.Schema{type: t} -> t
          %OpenApiSpex.Reference{} -> :map
          _ -> :string
        end

      {name, type}
    end)
  end

  defp schema_properties(%OpenApiSpex.Schema{items: %_{}} = schema, spec) do
    schema_properties(schema.items, spec)
  end

  defp schema_properties(%OpenApiSpex.Schema{}, _spec), do: nil

  defp schema_properties(_other, _spec), do: nil

  # ── Changeset code generation ─────────────────────────────────────────

  defp changeset_code(op, tag, spec) do
    struct_module = "#{context_module(tag)}.#{Macro.camelize(resource_singular(tag))}"

    case request_body_schema(op, spec) do
      %OpenApiSpex.Schema{properties: props} when is_map(props) ->
        field_names = Map.keys(props) |> Enum.map(&Atom.to_string/1)

        required_names =
          case request_body_schema(op, spec) do
            %OpenApiSpex.Schema{required: req} when is_list(req) ->
              Enum.map(req, &Atom.to_string/1)

            _ ->
              []
          end

        generate_changeset(field_names, required_names, struct_module)

      _ ->
        "    # No request body schema defined"
    end
  end

  defp generate_changeset(fields, required, struct_module) do
    cast_fields = Enum.map_join(fields, ", ", &inspect/1)
    required_fields = Enum.map_join(required, ", ", &inspect/1)

    cast_line =
      if fields == [] do
        "    changeset = Ecto.Changeset.cast({%{}, #{struct_module}}, params, [])"
      else
        "    changeset =\n      {%{}, #{struct_module}}\n      |> Ecto.Changeset.cast(params, [#{cast_fields}])"
      end

    validate_line =
      if required == [] do
        ""
      else
        "\n      |> Ecto.Changeset.validate_required([#{required_fields}])"
      end

    """
    #{cast_line}#{validate_line}
    """
  end
end
