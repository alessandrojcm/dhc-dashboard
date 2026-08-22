defmodule Dhc.Email.ApiClient do
  @moduledoc """
  Swoosh api_client that adds an Idempotency-Key HTTP header to every
  outgoing provider request (ADR 0021).

  This client wraps `Swoosh.ApiClient.Finch` and lifts the
  `:idempotency_key` provider option onto requests from adapters that do not
  support it themselves:

      email
      |> put_provider_option(:idempotency_key, "oban-1234")
      |> Dhc.Email.Mailer.deliver()
      # => POST with header {"Idempotency-Key", "oban-1234"}

  `Swoosh.Adapters.Resend` supplies the header itself. In that case this
  wrapper preserves the existing header rather than duplicating it.

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
    case {provider_options[:idempotency_key], has_idempotency_header?(headers)} do
      {nil, _present?} -> headers
      {_key, true} -> headers
      {key, false} when is_binary(key) -> [{@header_name, key} | headers]
    end
  end

  defp has_idempotency_header?(headers) do
    Enum.any?(headers, fn {name, _value} ->
      String.downcase(name) == String.downcase(@header_name)
    end)
  end
end
