defmodule Dhc.Resend.Receiving do
  @moduledoc """
  Reads received emails from Resend's receiving API over Req (ALE-409).

  Uses `RESEND_RECEIVING_API_KEY` (`config :dhc, :resend_receiving_api_key`),
  a full-access key: the production sending key (`RESEND_API_KEY`) is
  send-only and cannot read received mail. Sending stays on the Swoosh seam
  (`Dhc.Email.Mailer`, ADR 0021).

    * `get_email/1` — `GET /emails/receiving/:id?html_format=cid`, so inline
      images stay `cid:` references that match their attachments'
      `content_id`;
    * `list_attachments/1` — `GET /emails/receiving/:id/attachments`, each
      with a signed `download_url`;
    * `download/1` — fetches a signed attachment or raw-email URL (no API key:
      the URL is the credential).

  Errors are closed atoms or `{:http_status, status}` so no URL, address or
  body can reach a log or Sentry through an error term. Req's own retry is
  off: the Oban job that calls this module retries.

  Tests stub Resend with `Req.Test.stub(Dhc.Resend, plug)`; `config/test.exs`
  sets `:resend_req_options` to `plug: {Req.Test, Dhc.Resend}`.
  """

  @id_format ~r/\A[0-9A-Za-z_-]{1,128}\z/

  @type error ::
          :not_configured
          | :invalid_id
          | :transport
          | :invalid_response
          | {:http_status, pos_integer()}

  @doc "The received email, with `html_format=cid`."
  @spec get_email(String.t()) :: {:ok, map()} | {:error, error()}
  def get_email(id) do
    with :ok <- valid_id(id),
         {:ok, %{} = body} <- api_get("/emails/receiving/#{id}", html_format: "cid") do
      {:ok, body}
    else
      {:ok, _not_an_object} -> {:error, :invalid_response}
      error -> error
    end
  end

  @doc "The received email's attachments, each with a signed `download_url`."
  @spec list_attachments(String.t()) :: {:ok, [map()]} | {:error, error()}
  def list_attachments(id) do
    with :ok <- valid_id(id),
         {:ok, %{"data" => data}} when is_list(data) <-
           api_get("/emails/receiving/#{id}/attachments", []) do
      {:ok, data}
    else
      {:ok, _unexpected} -> {:error, :invalid_response}
      error -> error
    end
  end

  @doc "Downloads a signed attachment or raw-email URL."
  @spec download(String.t()) :: {:ok, binary()} | {:error, error()}
  def download(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) ->
        [url: url, decode_body: false]
        |> request()
        |> body()

      _not_https ->
        {:error, :invalid_response}
    end
  end

  def download(_url), do: {:error, :invalid_response}

  @doc "Whether `id` has the shape of a Resend email id (safe in a URL path and a key)."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_format, id)
  def valid_id?(_id), do: false

  defp valid_id(id), do: if(valid_id?(id), do: :ok, else: {:error, :invalid_id})

  defp api_get(path, params) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        [base_url: api_url(), url: path, params: params, auth: {:bearer, key}]
        |> request()
        |> body()

      _unset ->
        {:error, :not_configured}
    end
  end

  defp request(options) do
    options
    |> Keyword.merge(retry: false, receive_timeout: 30_000)
    |> Keyword.merge(Application.get_env(:dhc, :resend_req_options, []))
    |> Req.new()
    |> Req.get()
  end

  defp body({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp body({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}
  defp body({:error, _exception}), do: {:error, :transport}

  defp api_url, do: Application.get_env(:dhc, :resend_api_url, "https://api.resend.com")
  defp api_key, do: Application.get_env(:dhc, :resend_receiving_api_key)
end
