defmodule IdempotencyPlug.RequestPayloadFingerprintMismatchError do
  @moduledoc """
  Fingerprint-mismatch error vendored from `danschultzer/idempotency_plug`
  v0.2.2 (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT
  licensed.
  """

  defexception [
    :fingerprint,
    message: "This Idempotency-Key cannot be reused with a different payload or URI",
    plug_status: :unprocessable_entity
  ]
end
