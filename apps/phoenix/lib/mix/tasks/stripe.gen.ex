defmodule Mix.Tasks.Stripe.Gen do
  @moduledoc """
  Downloads the Stripe OpenAPI spec, trims it to our needed operations,
  and generates the typed Elixir client via `oapi_generator`.

  ## Usage

      mix stripe.gen

  ## What it does

  1. Downloads the latest Stripe OpenAPI spec from GitHub
  2. Trims it to only the operations listed in `@allowed_operations`
  3. Resolves transitive schema dependencies (so generated code compiles)
  4. Writes a trimmed spec to a temp file
  5. Runs `mix api.gen stripe` against the trimmed spec

  ## Adding new Stripe endpoints

  1. Add the operation ID to `@allowed_operations` below
  2. Run `mix stripe.gen` (or `mise run stripe-gen` from the repo root)
  """

  use Mix.Task

  @shortdoc "Download Stripe OpenAPI spec and generate typed Elixir client"

  @stripe_spec_url "https://raw.githubusercontent.com/stripe/openapi/refs/heads/master/latest/openapi.spec3.json"

  @allowed_operations MapSet.new([
                        # Subscriptions
                        "GetSubscriptions",
                        "PostSubscriptions",
                        "GetSubscriptionsSubscriptionExposedId",
                        "PostSubscriptionsSubscriptionExposedId",
                        "DeleteSubscriptionsSubscriptionExposedId",
                        "PostSubscriptionsSubscriptionResume",
                        # Prices
                        "GetPrices",
                        "GetPricesPrice",
                        "PostPrices",
                        # Customers
                        "GetCustomers",
                        "GetCustomersCustomer",
                        "PostCustomers"
                      ])

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start", [])

    tmp_dir = System.tmp_dir!()
    spec_path = Path.join(tmp_dir, "stripe-openapi.json")
    trimmed_path = Path.join(tmp_dir, "stripe-openapi-trimmed.json")

    # 1. Download the spec
    Mix.shell().info("[stripe:gen] Downloading Stripe OpenAPI spec...")

    case Req.get(@stripe_spec_url, decode_body: false, receive_timeout: 60_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.write!(spec_path, body)
        Mix.shell().info("[stripe:gen] Downloaded spec to #{spec_path}")

      {:ok, %Req.Response{status: status}} ->
        Mix.shell().error("[stripe:gen] Failed to download spec: HTTP #{status}")
        Mix.raise("Download failed with status #{status}")

      {:error, exception} ->
        Mix.shell().error("[stripe:gen] Failed to download spec: #{inspect(exception)}")
        Mix.raise("Download failed: #{Exception.message(exception)}")
    end

    # 2. Read and parse
    Mix.shell().info("[stripe:gen] Parsing spec...")
    spec = File.read!(spec_path) |> Jason.decode!()

    # 3. Trim paths
    {filtered_paths, path_count, orig_path_count} = trim_paths(spec)

    # 4. Collect schema refs and resolve transitively
    {filtered_schemas, schema_count, orig_schema_count} = trim_schemas(spec, filtered_paths)

    # 5. Build trimmed spec
    trimmed = %{
      "openapi" => spec["openapi"],
      "info" => spec["info"],
      "servers" => spec["servers"],
      "paths" => filtered_paths,
      "components" => Map.put(spec["components"] || %{}, "schemas", filtered_schemas)
    }

    # 6. Write trimmed spec
    File.write!(trimmed_path, Jason.encode!(trimmed))
    trimmed_size = File.stat!(trimmed_path).size

    Mix.shell().info("""
    [stripe:gen] Trimmed spec:
      Paths: #{orig_path_count} -> #{path_count}
      Schemas: #{orig_schema_count} -> #{schema_count}
      Size: #{div(File.stat!(spec_path).size, 1024)}KB -> #{div(trimmed_size, 1024)}KB
    """)

    # 7. Remove previous generated code
    generated_dir = Path.join(["lib", "dhc", "stripe", "generated"])

    if File.dir?(generated_dir) do
      Mix.shell().info("[stripe:gen] Removing previous generated code...")
      File.rm_rf!(generated_dir)
    end

    # 8. Run oapi_generator
    Mix.shell().info("[stripe:gen] Generating client from trimmed spec...")
    Mix.Task.run("api.gen", ["stripe", trimmed_path])

    # 9. Cleanup temp files
    File.rm(spec_path)
    File.rm(trimmed_path)

    Mix.shell().info("[stripe:gen] Done! Generated client in #{generated_dir}/")
  end

  defp trim_paths(spec) do
    orig_path_count = map_size(spec["paths"] || %{})

    filtered =
      spec["paths"]
      |> Enum.filter(fn {_path, methods} ->
        methods
        |> Enum.any?(fn {method, details} ->
          http_method?(method) and
            is_map(details) and
            Map.get(details, "operationId") in @allowed_operations
        end)
      end)
      |> Map.new()

    {filtered, map_size(filtered), orig_path_count}
  end

  defp trim_schemas(spec, filtered_paths) do
    orig_schema_count = map_size(spec["components"]["schemas"] || %{})

    # Collect initial refs from filtered paths
    refs = collect_refs_from_paths(filtered_paths)

    # Resolve transitive refs (schemas referencing other schemas)
    resolved_refs = resolve_transitive_refs(refs, spec["components"]["schemas"] || %{})

    # Filter schemas
    filtered =
      resolved_refs
      |> Enum.map(fn ref ->
        name = String.replace(ref, "#/components/schemas/", "")
        {name, spec["components"]["schemas"][name]}
      end)
      |> Enum.reject(fn {_name, schema} -> is_nil(schema) end)
      |> Map.new()

    {filtered, map_size(filtered), orig_schema_count}
  end

  defp http_method?(method), do: method in ["get", "post", "put", "patch", "delete"]

  defp collect_refs_from_paths(filtered_paths) do
    refs = MapSet.new()

    Enum.reduce(filtered_paths, refs, fn {_path, methods}, acc ->
      Enum.reduce(methods, acc, fn {_method, details}, inner_acc ->
        if is_map(details) do
          collect_refs(details, inner_acc)
        else
          inner_acc
        end
      end)
    end)
  end

  defp collect_refs(obj, acc) when is_map(obj) do
    acc = if obj["$ref"], do: MapSet.put(acc, obj["$ref"]), else: acc

    Enum.reduce(Map.values(obj), acc, fn value, inner_acc ->
      collect_refs(value, inner_acc)
    end)
  end

  defp collect_refs(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn item, inner_acc ->
      collect_refs(item, inner_acc)
    end)
  end

  defp collect_refs(_other, acc), do: acc

  defp resolve_transitive_refs(initial_refs, all_schemas) do
    resolve_refs(initial_refs, all_schemas, 0, 20)
  end

  defp resolve_refs(refs, _schemas, depth, max_depth) when depth >= max_depth, do: refs

  defp resolve_refs(refs, schemas, depth, max_depth) do
    new_refs =
      Enum.reduce(refs, MapSet.new(), fn ref, acc ->
        name = String.replace(ref, "#/components/schemas/", "")
        schema = Map.get(schemas, name)

        if is_map(schema) do
          collect_refs(schema, acc)
        else
          acc
        end
      end)

    merged = MapSet.union(refs, new_refs)

    if MapSet.size(merged) == MapSet.size(refs) do
      # No new refs found, we're done
      merged
    else
      resolve_refs(merged, schemas, depth + 1, max_depth)
    end
  end
end
