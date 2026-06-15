defmodule Mix.Tasks.Gen.Controllers do
  @moduledoc """
  Generates Phoenix controllers, JSON renderers, and contract tests from an OpenAPI spec.

  Reads `priv/api/openapi.yaml` and emits one controller, one JSON
  renderer, and one test file per tag found in the spec's operations.

  ## Usage

      mix gen.controllers              # generate from priv/api/openapi.yaml
      mix gen.controllers --force      # overwrite all existing files
      mix gen.controllers --force=<path> # overwrite a specific file

  ## Output

  For each unique tag found (e.g. `Widgets`), the task generates:

    - `lib/dhc_web/controllers/<tag>_controller.ex`
    - `lib/dhc_web/controllers/<tag>_json.ex`
    - `test/dhc_web/controllers/<tag>_controller_test.exs`
    - A router entry printed to the console

  Existing files are skipped by default. Pass `--force` to overwrite all,
  or `--force=lib/dhc_web/controllers/foo_controller.ex` to overwrite a specific file.

  ## OpenAPI Conventions

  - Each operation **must** be tagged with exactly one tag.
  - The tag name determines the controller name. E.g. tag `Widgets` produces
    `DhcWeb.WidgetsController`.
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

    tags = unique_tags(spec)

    if Enum.empty?(tags) do
      Mix.shell().info("No tagged operations found in #{@spec_file}.")
    else
      Mix.shell().info("Found tags: #{Enum.join(tags, ", ")}")

      Enum.each(tags, fn tag ->
        generate_controller(tag, spec, opts)
        generate_json_renderer(tag, spec, opts)
        generate_contract_test(tag, spec, opts)
      end)

      print_router_entries(tags, spec)
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
      @http_verbs
      |> Enum.flat_map(fn verb ->
        case Map.get(path_item, verb) do
          %OpenApiSpex.Operation{tags: tags} when is_list(tags) -> tags
          _ -> []
        end
      end)
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
      |> Enum.filter(fn verb ->
        case Map.get(path_item, verb) do
          %OpenApiSpex.Operation{tags: tags} -> tag in (tags || [])
          _ -> false
        end
      end)
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

  # ── File generation ──────────────────────────────────────────────────

  defp generate_controller(tag, spec, opts) do
    module_name = controller_module(tag)
    file_path = controller_file_path(tag)

    unless write_file_permitted?(file_path, opts) do
      Mix.shell().info([:yellow, "  skip ", :reset, file_path, " (already exists)"])
    else
      content = controller_content(module_name, tag, spec)
      write_file!(file_path, content)
      Mix.shell().info([:green, "  create ", :reset, file_path])
    end
  end

  defp generate_json_renderer(tag, spec, opts) do
    module_name = json_module(tag)
    file_path = json_file_path(tag)

    unless write_file_permitted?(file_path, opts) do
      Mix.shell().info([:yellow, "  skip ", :reset, file_path, " (already exists)"])
    else
      content = json_renderer_content(module_name, tag, spec)
      write_file!(file_path, content)
      Mix.shell().info([:green, "  create ", :reset, file_path])
    end
  end

  defp generate_contract_test(tag, spec, opts) do
    file_path = contract_test_file_path(tag)

    unless write_file_permitted?(file_path, opts) do
      Mix.shell().info([:yellow, "  skip ", :reset, file_path, " (already exists)"])
    else
      content = contract_test_content(tag, spec)
      write_file!(file_path, content)
      Mix.shell().info([:green, "  create ", :reset, file_path])
    end
  end

  defp write_file_permitted?(file_path, opts) do
    full_path = Path.join(File.cwd!(), file_path)

    if not File.exists?(full_path) do
      true
    else
      case opts[:force] do
        :all -> true
        ^file_path -> true
        _ -> false
      end
    end
  end

  defp write_file!(file_path, content) do
    full_path = Path.join(File.cwd!(), file_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  # ── Controller module content ────────────────────────────────────────

  defp controller_content(module_name, tag, spec) do
    operations = operations_for_tag(spec, tag)
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

  defp schema_module_name(%OpenApiSpex.Reference{"$ref": "#/components/schemas/" <> name}, _tag) do
    context_module_from_schema(name)
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

    cond do
      # GET collection → index
      action == "index" ->
        """
          @doc \"\"\"
          #{method_str} #{op.path}
          \"\"\"
          def index(conn, _params) do
            #{r_plural} = #{ctx}.list_#{r_plural}()
            render(conn, :index, #{r_var}s: #{r_plural})
          end
        """

      # GET single → show
      action == "show" ->
        id_param = path_id_param(op) || "id"

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
      action == "create" ->
        assigns = if has_body, do: "params", else: "_params"

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
      action == "delete" ->
        id_param = path_id_param(op) || "id"

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
      action == "update" ->
        id_param = path_id_param(op) || "id"

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
      true ->
        id_param = path_id_param(op) || "id"
        assigns = if has_body, do: "params", else: "_params"

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

  # ── JSON renderer module content ─────────────────────────────────────

  defp json_renderer_content(module_name, tag, spec) do
    operations = operations_for_tag(spec, tag)
    r_singular = resource_singular(tag)
    r_var = resource_var(tag)

    # Collect unique template names used by controller actions
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
            def render("index.json", %{#{r_var}s: #{r_var}s}) do
              %{data: Enum.map(#{r_var}s, &render_#{r_singular}/1)}
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
    fields = renderer_fields(tag, spec)

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

  defp renderer_fields(tag, spec) do
    # Find the first response schema that has a data property with fields
    ops = operations_for_tag(spec, tag)

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

        fields
        |> Enum.map(fn {name, _type} ->
          pad = String.duplicate(" ", max_len - String.length(Atom.to_string(name)))
          "          #{name}:#{pad} #{r_var}.#{name}"
        end)
        |> Enum.join(",\n")
    end
  end

  # ── Contract test content ────────────────────────────────────────────

  defp contract_test_content(tag, spec) do
    module_name = controller_test_module(tag)
    operations = operations_for_tag(spec, tag)
    test_cases = Enum.map(operations, &contract_test_case(&1, tag))

    """
    defmodule #{module_name} do
      use DhcWeb.ConnCase, async: true

    #{Enum.join(test_cases, "\n")}
    end
    """
  end

  defp contract_test_case(op, _tag) do
    action = action_name(op)
    method = op.method |> to_string() |> String.upcase()
    status_code = expected_status(op)
    phx_path = contract_test_path(op)
    http_method = op.method |> to_string() |> String.downcase()

    body =
      cond do
        op.operation.requestBody != nil ->
          """
              conn = #{http_method}(conn, "#{phx_path}", %{})
              assert json_response(conn, #{status_code})
              assert %{"data" => _} = json_response(conn, #{status_code})
          """

        true ->
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

  defp print_router_entries(tags, spec) do
    Mix.shell().info("\n── Router entries (paste into lib/dhc_web/router.ex) ──")

    Enum.each(tags, fn tag ->
      operations = operations_for_tag(spec, tag)

      Enum.each(operations, fn op ->
        action = action_name(op)
        short_ctrl = String.split(controller_module(tag), ".") |> List.last()

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

    cond do
      # GET with no path params → collection index
      method == :get and params == [] ->
        "index"

      # GET with exactly one path param at the end → single resource show
      method == :get and has_trailing_param and length(params) == 1 ->
        "show"

      # POST with no path params → create
      method == :post and params == [] ->
        "create"

      # PUT/PATCH with exactly one path param at the end → update
      method in [:put, :patch] and has_trailing_param and length(params) == 1 ->
        "update"

      # DELETE with exactly one path param at the end → delete
      method == :delete and has_trailing_param and length(params) == 1 ->
        "delete"

      # Non-REST: use last non-parameter segment (e.g. POST /resources/{id}/renew → "renew")
      true ->
        segments
        |> Enum.reject(&param_segment?/1)
        |> List.last()
        |> Kernel.||("action")
    end
  end

  # ── Context helpers ──────────────────────────────────────────────────

  defp context_module(tag), do: "Dhc.#{Macro.camelize(tag)}"

  defp short_context_module(tag), do: Macro.camelize(tag)

  defp resource_singular(tag) do
    tag
    |> Macro.underscore()
    |> String.trim_trailing("s")
    |> then(fn
      "" -> Macro.underscore(tag)
      s -> s
    end)
  end

  defp resource_plural(tag) do
    tag |> Macro.underscore()
  end

  defp resource_var(tag) do
    tag |> Macro.underscore() |> String.trim_trailing("s")
  end

  # ── File path helpers ────────────────────────────────────────────────

  defp controller_file_path(tag) do
    Path.join(@controller_dir, "#{Macro.underscore(tag)}_controller.ex")
  end

  defp json_file_path(tag) do
    Path.join(@controller_dir, "#{Macro.underscore(tag)}_json.ex")
  end

  defp contract_test_file_path(tag) do
    Path.join(@test_dir, "#{Macro.underscore(tag)}_controller_test.exs")
  end

  # ── Action name resolution ───────────────────────────────────────────

  defp action_name(op) do
    derived = action_from_http(op.method, op.path)

    if op.operation_id do
      op_action = operation_id_to_action(op.operation_id)

      # If operationId specifies a standard REST action, prefer it over
      # the path-derived name (handles cases like GET /health/detailed
      # with operationId "health.show").
      if op_action in ~w(index show create update delete) do
        op_action
      else
        # Non-REST operationId: use it unless path derivation found a REST match
        if derived in ~w(index show create update delete) do
          derived
        else
          op_action
        end
      end
    else
      derived
    end
  end

  # ── Path analysis helpers ────────────────────────────────────────────

  defp param_segment?(segment) do
    String.starts_with?(segment, "{") and String.ends_with?(segment, "}")
  end

  defp path_id_param(op) do
    op.operation.parameters
    |> Enum.find(fn p -> p.in == :path end)
    |> case do
      nil -> nil
      param -> param.name
    end
  end

  defp contract_test_path(op) do
    # Convert /widgets/{id} → /api/widgets/1 (with placeholder values for path params)
    path =
      op.operation.parameters
      |> Enum.filter(&(&1.in == :path))
      |> Enum.reduce(op.path, fn param, acc ->
        String.replace(acc, "{#{param.name}}", "1")
      end)

    "/api" <> path
  end

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
    cast_fields = fields |> Enum.map(&inspect/1) |> Enum.join(", ")
    required_fields = required |> Enum.map(&inspect/1) |> Enum.join(", ")

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
