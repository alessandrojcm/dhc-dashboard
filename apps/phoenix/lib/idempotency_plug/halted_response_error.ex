defmodule IdempotencyPlug.HaltedResponseError do
  @moduledoc """
  Interrupted-response error vendored from `danschultzer/idempotency_plug`
  v0.2.2 (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT
  licensed.
  """

  defexception [
    :reason,
    message: "The original request was interrupted and cannot be recovered",
    plug_status: :internal_server_error
  ]
end
