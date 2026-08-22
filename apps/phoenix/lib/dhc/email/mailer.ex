defmodule Dhc.Email.Mailer do
  @moduledoc """
  The one transactional-email transport seam (ADR 0021 — Swoosh Is the Email
  Transport Seam).

  The adapter is chosen per environment purely through configuration under
  `config :dhc, Dhc.Email.Mailer`:

    * **prod** — `Swoosh.Adapters.Loops` with `api_key: System.get_env("LOOPS_API_KEY")`.
      The Loops→Resend cutover (ADR 0022) is a config flip to
      `Swoosh.Adapters.Resend`, not new code.
    * **dev** — `Swoosh.Adapters.Mailpit` over HTTP (`base_url:` pointing at
      the local Mailpit API, default `http://localhost:8025`).
    * **test** — `Swoosh.Adapters.Test`, asserted via `Swoosh.TestAssertions`.

  Callers build a `%Swoosh.Email{}` (see `Dhc.Email.Worker`) and call
  `deliver/2`. All adapters run over `Swoosh.ApiClient.Finch`; see
  `Dhc.Email.ApiClient` for the Idempotency-Key injection.
  """

  use Swoosh.Mailer, otp_app: :dhc
end
