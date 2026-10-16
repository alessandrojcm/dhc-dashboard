defmodule Mix.Tasks.Typesafe.Gen do
  @moduledoc """
  Downloads TypeSafe's published OpenAPI description and generates its typed
  Elixir request/response modules and operation wrapper.

      mix typesafe.gen

  The Req transport remains in `Dhc.TypeSafe.Client` so retry and privacy
  behavior stay owned by this application.
  """

  @shortdoc "Generate TypeSafe's typed Elixir client from OpenAPI"

  use Mix.Task

  @spec_url "https://api.typesafe.ai/openapi.json"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    spec_path = Path.join(System.tmp_dir!(), "typesafe-openapi.json")

    try do
      download_spec!(spec_path)

      generated_dir = Path.join(["lib", "dhc", "typesafe", "generated"])
      if File.dir?(generated_dir), do: File.rm_rf!(generated_dir)

      Mix.Task.run("api.gen", ["typesafe", spec_path])
      Mix.shell().info("[typesafe:gen] Generated typed API in #{generated_dir}/")
    after
      File.rm(spec_path)
    end
  end

  defp download_spec!(path) do
    Mix.shell().info("[typesafe:gen] Downloading TypeSafe OpenAPI spec...")

    case Req.get(@spec_url, decode_body: false, retry: false, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        File.write!(path, body)

      {:ok, %Req.Response{status: status}} ->
        Mix.raise("TypeSafe OpenAPI download failed with HTTP #{status}")

      {:error, _exception} ->
        Mix.raise("TypeSafe OpenAPI download failed")
    end
  end
end
