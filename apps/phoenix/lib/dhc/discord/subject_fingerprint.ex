defmodule Dhc.Discord.SubjectFingerprint do
  @moduledoc false

  @fingerprint_bytes 32
  @fingerprint_length @fingerprint_bytes * 2

  def generate(subject, key)
      when is_binary(subject) and subject != "" and is_binary(key) and key != "" do
    :crypto.mac(:hmac, :sha256, key, "discord:" <> subject)
    |> Base.encode16(case: :lower)
  end

  def valid?(fingerprint)
      when is_binary(fingerprint) and byte_size(fingerprint) == @fingerprint_length do
    String.match?(fingerprint, ~r/\A[0-9a-f]{64}\z/)
  end

  def valid?(_fingerprint), do: false
end
