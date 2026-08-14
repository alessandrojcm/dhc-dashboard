defmodule Dhc.Email.DevMailerStub do
  @moduledoc """
  Test double for `Dhc.Email.DevMailer`, wired up via the `:email_dev_mailer`
  app env in `config/test.exs`.

  Delivered messages are sent to the test process (set
  `Application.put_env(:dhc, :email_dev_mailer_test_pid, self())` and
  `assert_receive {:dev_email, fields}`). The stub's return value is
  configurable through `:email_dev_mailer_stub_result` (defaults to `:ok`) so
  tests can simulate an unreachable Mailpit relay.
  """

  def deliver(to, subject, body) do
    if pid = Application.get_env(:dhc, :email_dev_mailer_test_pid) do
      send(pid, {:dev_email, %{to: to, subject: subject, body: body}})
    end

    Application.get_env(:dhc, :email_dev_mailer_stub_result, :ok)
  end
end
