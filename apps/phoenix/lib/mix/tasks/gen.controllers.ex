defmodule Mix.Tasks.Gen.Controllers do
  @moduledoc """
  Generates Phoenix controllers and JSON renderers from an OpenAPI spec.

  Reads `priv/api/openapi.yaml` and emits one controller and one JSON
  renderer per tag found in the spec's operations.

  ## Usage

      mix gen.controllers          # generate from priv/api/openapi.yaml
      mix gen.controllers --force  # overwrite existing files

  ## Output

  For each unique tag found (e.g. `Health`), the task generates:

    - `lib/dhc_web/controllers/<tag>_controller.ex`
    - `lib/dhc_web/controllers/<tag>_json.ex`
    - A router entry printed to the console

  Existing files are skipped by default. Pass `--force` to overwrite.

  ## OpenAPI Conventions

  - Each operation **must** be tagged with exactly one tag.
  - The tag name determines the controller name. E.g. tag `Health` produces
    `DhcWeb.HealthController`.
  - The `operationId` follows the pattern `<tag>.<action>`. E.g.
    `health.index` maps to `HealthController.index/2`.
  - The `operationId` action name must be a valid Elixir function name.
  """

  use Mix.Task

  @shortdoc "Generate controllers and JSON renderers from an OpenAPI spec"

  @spec_file "priv/api/openapi.yaml"
  @output_lib "lib/dhc_web/controllers"

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
      end)

      print_router_entries(tags, spec)
    end
  end

  # ── Argument parsing ─────────────────────────────────────────────────

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [force: :boolean])

    %{force: Keyword.get(opts, :force, false)}
  end

  # ── Spec parsing ──────────────────────────────────────────────────────

  @http_verbs [:get, :post, :put, :patch, :delete]

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

    maybe_write_file(file_path, opts, fn ->
      controller_content(module_name, tag, spec)
    end)
  end

  defp generate_json_renderer(tag, spec, opts) do
    module_name = json_module(tag)
    file_path = json_file_path(tag)

    maybe_write_file(file_path, opts, fn ->
      json_renderer_content(module_name, tag, spec)
    end)
  end

  defp maybe_write_file(file_path, opts, content_fn) do
    full_path = Path.join(File.cwd!(), file_path)

    if File.exists?(full_path) and not opts[:force] do
      Mix.shell().info([:yellow, "  skip ", :reset, file_path, " (already exists)"])
    else
      content = content_fn.()
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
      Mix.shell().info([:green, "  create ", :reset, file_path])
    end
  end

  # ── Controller module content ────────────────────────────────────────

  defp controller_content(module_name, tag, spec) do
    operations = operations_for_tag(spec, tag)
    action_defs = Enum.map(operations, &action_definition/1)

    action_defs =
      if Enum.empty?(action_defs) do
        ""
      else
        Enum.join(action_defs, "\n") |> String.trim_trailing()
      end

    """
    defmodule #{module_name} do
      use DhcWeb, :controller

    #{action_defs}
    end
    """
  end

  defp action_definition(op) do
    action = operation_id_to_action(op.operation_id)
    method = op.method |> to_string() |> String.upcase()

    """
      @doc \"\"\"
      #{method} #{op.path}
      \"\"\"
      def #{action}(conn, _params) do
        json(conn, %{data: %{status: "ok"}})
      end
    """
  end

  # ── JSON renderer module content ─────────────────────────────────────

  defp json_renderer_content(module_name, tag, spec) do
    operations = operations_for_tag(spec, tag)

    render_clauses =
      Enum.map(operations, fn op ->
        action = operation_id_to_action(op.operation_id)

        """
          def render("#{action}.json", _assigns) do
            %{data: %{status: "ok"}}
          end
        """
      end)

    render_clauses =
      if Enum.empty?(render_clauses) do
        ""
      else
        Enum.join(render_clauses, "\n") |> String.trim_trailing()
      end

    """
    defmodule #{module_name} do
      @moduledoc false

    #{render_clauses}
    end
    """
  end

  # ── Router entries ───────────────────────────────────────────────────

  defp print_router_entries(tags, spec) do
    Mix.shell().info("\n── Router entries (paste into lib/dhc_web/router.ex) ──")

    Enum.each(tags, fn tag ->
      operations = operations_for_tag(spec, tag)

      Enum.each(operations, fn op ->
        action = operation_id_to_action(op.operation_id)

        route =
          ~s|#{op.method} "#{op.path}", #{String.split(controller_module(tag), ".") |> List.last()}, :#{action}|

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

  # ── File path helpers ────────────────────────────────────────────────

  defp controller_file_path(tag) do
    Path.join(@output_lib, "#{Macro.underscore(tag)}_controller.ex")
  end

  defp json_file_path(tag) do
    Path.join(@output_lib, "#{Macro.underscore(tag)}_json.ex")
  end
end
