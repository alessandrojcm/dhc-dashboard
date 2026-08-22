defmodule Dhc.Email.ApiClient do
  @moduledoc """
  Swoosh api_client that adds an Idempotency-Key HTTP header to every
  outgoing provider request (ADR 0021).

  Swoosh's first-party adapters hard-code their HTTP request headers, so an
  `Idempotency-Key` set via `Swoosh.Email.header/3` never reaches the wire.
  This client wraps `Swoosh.ApiClient.Finch` and lifts the
  `:idempotency_key` provider option onto the request instead:

      email
      |> put_provider_option(:idempotency_key, "oban-1234")
      |> Dhc.Email.Mailer.deliver()
      # => POST with header {"Idempotency-Key", "oban-1234"}

  Because it sits below the adapter layer, the header survives the Loops →
  Resend cutover unchanged. Remove this wrapper if upstream Swoosh ever grows
  first-party idempotency support.

  Wired globally via `config :swoosh, api_client: Dhc.Email.ApiClient`; the
  Finch instance is named by `config :swoosh, :finch_name` (default
  `Swoosh.Finch`, supervised in `Dhc.Application`).
  """

  @behaviour Swoosh.ApiClient

  @header_name "Idempotency-Key"

  @impl true
  def init, do: Swoosh.ApiClient.Finch.init()

  @impl true
  def post(url, headers, body, %Swoosh.Email{} = email) do
    Swoosh.ApiClient.Finch.post(url, idempotency_header(headers, email), body, email)
  end

  @doc """
  Prepends `{"Idempotency-Key", key}` to `headers` when `email` carries the
  `:idempotency_key` provider option; returns `headers` untouched otherwise.
  """
  @spec idempotency_header(Swoosh.ApiClient.headers(), Swoosh.Email.t()) ::
          Swoosh.ApiClient.headers()
  def idempotency_header(headers, %Swoosh.Email{provider_options: provider_options}) do
    case provider_options[:idempotency_key] do
      nil -> headers
      key when is_binary(key) -> [{@header_name, key} | headers]
    end
  end
end
