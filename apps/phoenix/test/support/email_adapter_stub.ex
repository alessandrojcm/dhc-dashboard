defmodule Dhc.Email.AdapterStub do
  @moduledoc """
  Configurable Swoosh adapter double used to exercise
  `Dhc.Email.Worker`'s delivery-failure classification (ADR 0021).

  Wire it through the mailer's own app env — the stub reads its canned result
  from the same configuration it is handed at deliver time:

      Application.put_env(:dhc, Dhc.Email.Mailer,
        adapter: Dhc.Email.AdapterStub,
        stub_result: {:error, {429, %{"message" => "rate limited"}}}
      )

  `stub_result` defaults to `{:ok, %{}}` (a successful delivery).
  """

  # No required_config: the stub accepts whatever mailer config it is handed.
  use Swoosh.Adapter

  def deliver(_email, config) do
    Keyword.get(config, :stub_result, {:ok, %{}})
  end
end
