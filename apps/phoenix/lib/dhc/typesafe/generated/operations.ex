defmodule Dhc.TypeSafe.Operations do
  @moduledoc """
  Provides API endpoints related to operations
  """

  @default_client Dhc.TypeSafe.Client

  @doc """
  Models V1

  List the models and aliases available to the authenticated account.

  Pass a returned model name as `model` in a POST /v1/systemone request.
  """
  @spec models_v1_v1_models_get(opts :: keyword) ::
          {:ok, Dhc.TypeSafe.ModelMetadataList.t()}
          | {:error, Dhc.TypeSafe.HTTPValidationError.t()}
  def models_v1_v1_models_get(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Dhc.TypeSafe.Operations, :models_v1_v1_models_get},
      url: "/v1/models",
      method: :get,
      response: [
        {200, {Dhc.TypeSafe.ModelMetadataList, :t}},
        {422, {Dhc.TypeSafe.HTTPValidationError, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Systemone

  Answer one or more questions about the content supplied in `state`.

  You can mix question types in one request. Answers use the same names as the
  questions, so you can match each result to its question. The response also includes
  the model used and token usage.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec systemone_v1_systemone_post(body :: Dhc.TypeSafe.SystemOneRequest.t(), opts :: keyword) ::
          {:ok, Dhc.TypeSafe.SystemOneResponse.t()}
          | {:error, Dhc.TypeSafe.HTTPValidationError.t()}
  def systemone_v1_systemone_post(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.TypeSafe.Operations, :systemone_v1_systemone_post},
      url: "/v1/systemone",
      body: body,
      method: :post,
      request: [{"application/json", {Dhc.TypeSafe.SystemOneRequest, :t}}],
      response: [
        {200, {Dhc.TypeSafe.SystemOneResponse, :t}},
        {422, {Dhc.TypeSafe.HTTPValidationError, :t}}
      ],
      opts: opts
    })
  end
end
