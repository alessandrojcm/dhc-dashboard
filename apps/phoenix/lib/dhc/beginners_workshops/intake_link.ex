defmodule Dhc.BeginnersWorkshops.IntakeLink do
  @moduledoc """
  The Intake capability link (ALE-380; ALE-374 "Intake link and Intake
  page").

  The token is `HMAC(server secret, Intake id + link generation)`, so the app
  can rebuild the link whenever it queues an email, and only its SHA-256 hash
  is stored (unique, for lookup) — a database leak reveals no links. Rotating
  a link increments the generation, which changes the token.

  The server secret is derived from the endpoint's `secret_key_base` under a
  purpose-specific salt, so it is never the raw base secret.

  The link opens the public Intake page at `<APP_URL>/beginners/intake/<token>`.
  """

  @salt "beginners-workshop intake link"

  @doc "The token for an Intake id at a link generation (URL-safe, unpadded)."
  @spec token(binary(), pos_integer()) :: String.t()
  def token(intake_id, generation)
      when is_binary(intake_id) and is_integer(generation) and generation >= 1 do
    :hmac
    |> :crypto.mac(:sha256, key(), "#{intake_id}:#{generation}")
    |> Base.url_encode64(padding: false)
  end

  @doc "The stored lookup hash of a token."
  @spec hash(String.t()) :: binary()
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "The Intake page URL for a token."
  @spec url(String.t()) :: String.t()
  def url(token) when is_binary(token),
    do:
      "#{String.trim_trailing(Application.fetch_env!(:dhc, :app_url), "/")}/beginners/intake/#{token}"

  defp key do
    DhcWeb.Endpoint.config(:secret_key_base)
    |> Plug.Crypto.KeyGenerator.generate(@salt, length: 32, cache: Plug.Crypto.Keys)
  end
end
