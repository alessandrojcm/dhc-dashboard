defmodule Dhc.Stripe.ReturnUrl do
  @moduledoc """
  Whether Stripe may send a person back to a `return_url` this app offered.

  `return_url` values reach Stripe's Checkout/portal sessions, and Stripe may
  navigate the person to them after payment. Only URLs on the dashboard's own
  origin (scheme + host + port of `:app_url`) are accepted; any path on that
  origin is fine. Userinfo is refused so `https://app@evil.com`-style links
  cannot look like the dashboard.

  Callers translate a refusal into their own reason atom — the Workshops
  Checkout keeps `:invalid_return_url`, Membership keeps `:invalid_payload`.
  """

  @spec same_origin?(term()) :: boolean()
  def same_origin?(url) do
    case validate(url) do
      :ok -> true
      _ -> false
    end
  end

  def validate(url) when is_binary(url) do
    # Stripe's `{CHECKOUT_SESSION_ID}` template placeholder is not a legal
    # URI character; the origin check only needs scheme/host/port, so strip
    # it before parsing.
    case URI.new(strip_placeholder(url)) do
      {:ok, %URI{userinfo: nil} = uri} ->
        with {:ok, app_uri} <- URI.new(Application.fetch_env!(:dhc, :app_url)),
             {:ok, app_origin} <- origin(app_uri),
             {:ok, ^app_origin} <- origin(uri) do
          :ok
        else
          _ -> {:error, :off_origin}
        end

      _ ->
        {:error, :off_origin}
    end
  end

  def validate(_url), do: {:error, :off_origin}

  defp strip_placeholder(url), do: String.replace(url, ~r/\{[^}]*\}/, "CHECKOUT_SESSION_ID")

  defp origin(%URI{scheme: scheme, host: host, port: port})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: {:ok, {scheme, String.downcase(host), port}}

  defp origin(_uri), do: :error
end
