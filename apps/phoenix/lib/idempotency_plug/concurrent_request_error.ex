defmodule IdempotencyPlug.ConcurrentRequestError do
  @moduledoc """
  Concurrent-request error vendored from `danschultzer/idempotency_plug` v0.2.2
  (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT licensed.
  """

  defexception message: "A request with the same Idempotency-Key is currently being processed",
               plug_status: :conflict
end
