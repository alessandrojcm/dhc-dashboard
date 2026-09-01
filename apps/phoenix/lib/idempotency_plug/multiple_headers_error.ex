defmodule IdempotencyPlug.MultipleHeadersError do
  @moduledoc """
  Multiple-key error vendored from `danschultzer/idempotency_plug` v0.2.2
  (upstream commit `6692067c4a1e1ddacb1f598a544f9c7171123ee4`), MIT licensed.
  """

  defexception message: "Expected one Idempotency-Key header, got multiple",
               plug_status: :bad_request
end
