defmodule IdempotencyPlug.Store do
  @moduledoc """
  Storage contract vendored from `danschultzer/idempotency_plug` v0.2.2
  (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT licensed.

  The durable Ecto implementation is the application seam; the upstream ETS
  store is intentionally not vendored because response replays must survive
  restarts and span Phoenix nodes.
  """

  @type options :: keyword()
  @type request_id :: binary()
  @type fingerprint :: binary()
  @type data :: term()
  @type expires_at :: DateTime.t()

  @callback setup(options()) :: :ok | {:error, term()}
  @callback lookup(request_id(), options()) :: {data(), fingerprint(), expires_at()} | :not_found

  @callback insert(request_id(), data(), fingerprint(), expires_at(), options()) ::
              :ok | {:error, term()}

  @callback update(request_id(), data(), expires_at(), options()) :: :ok | {:error, term()}
  @callback prune(options()) :: :ok
end
