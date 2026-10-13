defmodule Dhc.TypeSafe.Client do
  @moduledoc """
  Req transport adapter for the generated TypeSafe OpenAPI operations.

  The generated request and response types come from TypeSafe's OpenAPI 3.1
  contract (`mix typesafe.gen`). This adapter owns our bearer key, Req.Test
  seam, 429/529 retry policy and closed error mapping. It never logs request or
  response bodies because they contain private correspondence.
  """

  @type error :: :not_configured | :transport | {:http_status, pos_integer()}

  @doc "Performs a generated TypeSafe operation over Req."
  @spec request(map() | keyword()) :: {:ok, map()} | {:error, error()}
  def request(opts) when is_map(opts), do: opts |> Map.to_list() |> request()

  def request(opts) do
    case Application.get_env(:dhc, :typesafe_api_key) do
      key when is_binary(key) and key != "" -> send_request(opts, key)
      _unset -> {:error, :not_configured}
    end
  end

  defp send_request(opts, api_key) do
    request_options = [
      method: Keyword.fetch!(opts, :method),
      base_url: Application.get_env(:dhc, :typesafe_api_url, "https://api.typesafe.ai"),
      url: Keyword.fetch!(opts, :url),
      headers: [{"authorization", "Bearer #{api_key}"}],
      retry: &retryable_response?/2,
      max_retries: 3,
      retry_log_level: false,
      receive_timeout: 30_000
    ]

    request_options =
      case Keyword.get(opts, :body) do
        %_{} = body -> Keyword.put(request_options, :json, Map.from_struct(body))
        body when is_map(body) -> Keyword.put(request_options, :json, body)
        nil -> request_options
      end

    request_options
    |> Keyword.merge(Application.get_env(:dhc, :typesafe_req_options, []))
    |> Req.new()
    |> Req.request()
    |> response()
  end

  defp response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp response({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}
  defp response({:error, _exception}), do: {:error, :transport}

  defp retryable_response?(_request, %Req.Response{status: status}), do: status in [429, 529]
  defp retryable_response?(_request, _exception), do: false
end
