defmodule IdempotencyPlug.EctoStore do
  @moduledoc """
  Durable Ecto store vendored from `danschultzer/idempotency_plug` v0.2.2
  (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT licensed.

  Local adaptation: the hand-written DHC migration owns
  `idempotency_plug_requests`; the upstream migration generator is omitted.
  """

  @behaviour IdempotencyPlug.Store

  import Ecto.Query

  alias IdempotencyPlug.IdempotentRequest

  @impl true
  def setup(options), do: repo(options) |> setup_repo()

  @impl true
  def lookup(request_id, options) do
    case repo!(options).get(IdempotentRequest, request_id) do
      nil -> :not_found
      request -> lookup_unexpired(request, options)
    end
  end

  @impl true
  def insert(request_id, data, fingerprint, expires_at, options) do
    %IdempotentRequest{
      id: request_id,
      data: data,
      fingerprint: fingerprint,
      expires_at: expires_at
    }
    |> IdempotentRequest.changeset()
    |> repo!(options).insert()
    |> case do
      {:ok, _request} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def update(request_id, data, expires_at, options) do
    IdempotentRequest
    |> where(id: ^request_id)
    |> repo!(options).update_all(
      set: [data: data, expires_at: expires_at, updated_at: DateTime.utc_now()]
    )
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, "key #{request_id} not found in store"}
    end
  end

  @impl true
  def prune(options) do
    IdempotentRequest
    |> where([request], request.expires_at < ^DateTime.utc_now())
    |> repo!(options).delete_all()

    :ok
  end

  defp setup_repo({:ok, _repo}), do: :ok
  defp setup_repo({:error, error}), do: {:error, error}

  defp lookup_unexpired(%{expires_at: expires_at} = request, options) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      {request.data, request.fingerprint, expires_at}
    else
      delete_expired(request, options)
    end
  end

  defp delete_expired(request, options) do
    case repo!(options).delete(request) do
      {:ok, _request} -> :not_found
      {:error, _changeset} -> :not_found
    end
  end

  defp repo(options) do
    case Keyword.fetch(options, :repo) do
      {:ok, repo} -> {:ok, repo}
      :error -> {:error, ":repo must be specified in options for #{inspect(__MODULE__)}"}
    end
  end

  defp repo!(options) do
    case repo(options) do
      {:ok, repo} -> repo
      {:error, error} -> raise error
    end
  end
end
