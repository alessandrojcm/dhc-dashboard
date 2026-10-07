defmodule Dhc.Email.WorkerTest do
  # async: false — swaps :environment and the Dhc.Email.Mailer adapter via
  # application env (house seam pattern), which cannot race across tests.
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Dhc.Email.Worker

  @job_id 42

  @valid_args %{
    "email" => "user@example.com",
    "transactional_id" => "inviteMember",
    "data_variables" => %{
      "INVITEE_FIRST_NAME" => "Alice",
      "INVITATION_LINK" => "https://example.com/invite"
    }
  }

  defp job(args, id \\ @job_id), do: %Oban.Job{id: id, args: args}

  setup do
    original_mailer = Application.get_env(:dhc, Dhc.Email.Mailer)
    original_env = Application.get_env(:dhc, :environment)

    on_exit(fn ->
      if original_mailer do
        Application.put_env(:dhc, Dhc.Email.Mailer, original_mailer)
      else
        Application.delete_env(:dhc, Dhc.Email.Mailer)
      end

      Application.put_env(:dhc, :environment, original_env)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Seam 1: the public worker contract, observed through Swoosh.TestAssertions
  # (test.exs wires Dhc.Email.Mailer to Swoosh.Adapters.Test).
  # ---------------------------------------------------------------------------

  describe "perform/1 delivers through the configured mailer" do
    test "sends the email kind and data variables to the recipient" do
      assert Worker.perform(job(@valid_args)) == :ok

      # One delivered email per job; assert everything on that single message
      # because assertions consume mailbox messages.
      assert_email_sent(fn email ->
        assert email.provider_options.template == %{
                 id: "invite-member",
                 variables: %{
                   "INVITEE_FIRST_NAME" => "Alice",
                   "INVITATION_LINK" => "https://example.com/invite"
                 }
               }

        assert Enum.any?(email.to, fn {_name, address} ->
                 address == "user@example.com"
               end)

        assert email.reply_to == {"", "contact@dublinhemaclub.com"}
      end)
    end

    test "carries an Idempotency-Key derived from the Oban job id" do
      assert Worker.perform(job(@valid_args)) == :ok

      assert_email_sent(
        to: "user@example.com",
        headers: %{"Idempotency-Key" => "oban-#{@job_id}"}
      )
    end

    test "decorates the message with a JSON summary for the dev inbox" do
      assert Worker.perform(job(@valid_args)) == :ok

      assert_email_sent(fn email ->
        assert email.subject == "[dev] Email: inviteMember"

        payload =
          email.text_body && Jason.decode!(email.text_body)

        assert payload["transactional_id"] == "inviteMember"
        assert payload["data_variables"]["INVITEE_FIRST_NAME"] == "Alice"

        assert payload["data_variables"]["INVITATION_LINK"] ==
                 "https://example.com/invite"
      end)
    end

    test "defaults data_variables to an empty map" do
      args = Map.delete(@valid_args, "data_variables")

      assert Worker.perform(job(args)) == :ok

      assert_email_sent(fn email ->
        assert email.provider_options.template.variables == %{}
      end)
    end

    test "accepts numeric data variable values" do
      args = %{
        "email" => "user@example.com",
        "transactional_id" => "workshopAnnouncement",
        "data_variables" => %{"WORKSHOP_COUNT" => 5, "MEMBER_FIRST_NAME" => "Bob"}
      }

      assert Worker.perform(job(args)) == :ok

      assert_email_sent(fn email ->
        assert email.provider_options.template == %{
                 id: "workshop-announcement",
                 variables: %{"WORKSHOP_COUNT" => 5, "MEMBER_FIRST_NAME" => "Bob"}
               }
      end)
    end

    test "derives every Resend template alias from the email kind" do
      aliases = %{
        "inviteMember" => "invite-member",
        "workshopAnnouncement" => "workshop-announcement",
        "workshopRegistration" => "workshop-registration",
        "workshopRegistrationError" => "workshop-registration-error",
        "magicLink" => "magic-link"
      }

      for {kind, template_alias} <- aliases do
        args = %{"email" => "user@example.com", "transactional_id" => kind}

        assert Worker.perform(job(args)) == :ok

        assert_email_sent(fn email ->
          assert email.provider_options.template == %{id: template_alias, variables: %{}}
        end)
      end
    end
  end

  describe "perform/1 with invalid args" do
    test "returns {:cancel, ...} when email is missing" do
      args = Map.delete(@valid_args, "email")

      assert {:cancel, {:validation, errors}} = Worker.perform(job(args))
      assert "missing email" in errors
    end

    test "returns {:cancel, ...} when email is empty string" do
      args = Map.put(@valid_args, "email", "")

      assert {:cancel, {:validation, errors}} = Worker.perform(job(args))
      assert "missing email" in errors
    end

    test "returns {:cancel, ...} when email has invalid format" do
      args = Map.put(@valid_args, "email", "not-an-email")

      assert {:cancel, {:validation, errors}} = Worker.perform(job(args))
      assert "invalid email format" in errors
    end

    test "returns {:cancel, ...} when transactional_id is missing" do
      args = Map.delete(@valid_args, "transactional_id")

      assert {:cancel, {:validation, errors}} = Worker.perform(job(args))
      assert "missing transactional_id" in errors
    end

    test "returns {:cancel, ...} when transactional_id is unknown" do
      args = Map.put(@valid_args, "transactional_id", "unknownTemplate")

      assert {:cancel, {:validation, errors}} = Worker.perform(job(args))
      assert "invalid transactional_id" in errors
    end

    test "returns {:cancel, ...} when data_variables has non-string/number values" do
      args = put_in(@valid_args, ["data_variables", "link"], %{"nested" => "object"})

      assert {:cancel, {:validation, errors}} = Worker.perform(job(args))
      assert "data_variables values must be strings or numbers" in errors
    end

    test "accumulates multiple validation errors" do
      assert {:cancel, {:validation, errors}} = Worker.perform(job(%{}))
      assert "missing email" in errors
      assert "missing transactional_id" in errors
      assert "invalid transactional_id" in errors
    end

    test "never delivers when args are invalid" do
      refute_email_sent()
      Worker.perform(job(%{}))
      refute_email_sent()
    end
  end

  # ---------------------------------------------------------------------------
  # Seam 2: delivery-failure semantics. The mailer adapter is swapped for a
  # configurable stub (mirroring the :discord_adapter / :onboarding_stripe_adapter
  # seams) so classification can be exercised without real HTTP.
  # ---------------------------------------------------------------------------

  describe "perform/1 failure semantics in prod" do
    import ExUnit.CaptureLog

    setup do
      Application.put_env(:dhc, :environment, :prod)
      :ok
    end

    test "cancels deterministically when the provider rejects a 4xx validation family response" do
      stub_delivery({:error, {400, %{"message" => "Missing required data variable"}}})

      assert {:cancel, {:provider_rejected, 400}} = Worker.perform(job(@valid_args))
    end

    test "cancels on 422-style unprocessable content" do
      stub_delivery({:error, {422, %{"message" => "unprocessable"}}})

      assert {:cancel, {:provider_rejected, 422}} = Worker.perform(job(@valid_args))
    end

    test "retries on rate limiting (429)" do
      stub_delivery({:error, {429, %{"message" => "rate limited"}}})

      assert {:error, {429, %{"message" => "rate limited"}}} = Worker.perform(job(@valid_args))
    end

    test "retries on provider 5xx" do
      stub_delivery({:error, {503, "upstream unavailable"}})

      assert {:error, {503, "upstream unavailable"}} = Worker.perform(job(@valid_args))
    end

    test "retries on network errors" do
      stub_delivery({:error, %Mint.TransportError{reason: :econnrefused}})

      assert {:error, %Mint.TransportError{reason: :econnrefused}} =
               Worker.perform(job(@valid_args))
    end

    test "logs the failure before returning" do
      stub_delivery({:error, {503, "upstream unavailable"}})

      assert capture_log(fn -> Worker.perform(job(@valid_args)) end) =~ "503"
    end
  end

  describe "perform/1 failure semantics outside prod" do
    import ExUnit.CaptureLog

    # environment stays :test (set by config/test.exs); the mailer adapter
    # stands in for a stopped local Mailpit relay.
    test "swallows delivery failures so the dev queue never wedges" do
      stub_delivery({:error, %Mint.TransportError{reason: :econnrefused}})

      logs =
        capture_log(fn ->
          assert Worker.perform(job(@valid_args)) == :ok
        end)

      assert logs =~ "will not retry"
    end

    test "still swallows provider-side rejections outside prod" do
      stub_delivery({:error, {400, %{"message" => "nope"}}})

      assert Worker.perform(job(@valid_args)) == :ok
    end
  end

  describe "sealed data variables" do
    import ExUnit.CaptureLog

    @login_link "https://app.example.com/auth/magic-link?token=raw-secret-token"

    defp sealed_args(sealed) do
      %{
        "email" => "user@example.com",
        "transactional_id" => "magicLink",
        "data_variables" => %{},
        "sealed_data_variables" => sealed
      }
    end

    test "the sealed value does not contain the plaintext" do
      sealed = Worker.seal_data_variables(%{"LOGIN_LINK" => @login_link})

      refute sealed =~ "raw-secret-token"
      refute sealed =~ "magic-link"
    end

    test "delivers the unsealed variables to the template" do
      sealed = Worker.seal_data_variables(%{"LOGIN_LINK" => @login_link})

      assert Worker.perform(job(sealed_args(sealed))) == :ok

      assert_email_sent(fn email ->
        assert email.provider_options.template == %{
                 id: "magic-link",
                 variables: %{"LOGIN_LINK" => @login_link}
               }
      end)
    end

    test "cancels a tampered sealed value without sending or logging it" do
      sealed = Worker.seal_data_variables(%{"LOGIN_LINK" => @login_link})
      tampered = String.slice(sealed, 0..-6//1) <> "AAAAA"

      log =
        capture_log(fn ->
          assert {:cancel, {:sealed_data_variables, :invalid}} =
                   Worker.perform(job(sealed_args(tampered)))
        end)

      refute log =~ tampered
      refute_email_sent()
    end

    test "cancels an expired sealed value" do
      secret = DhcWeb.Endpoint.config(:secret_key_base)

      expired =
        Plug.Crypto.encrypt(
          secret,
          "dhc.email.worker sealed_data_variables v1",
          %{"LOGIN_LINK" => @login_link},
          signed_at: System.system_time(:second) - 16 * 60
        )

      capture_log(fn ->
        assert {:cancel, {:sealed_data_variables, :expired}} =
                 Worker.perform(job(sealed_args(expired)))
      end)

      refute_email_sent()
    end
  end

  describe "redaction of data variable values" do
    import ExUnit.CaptureLog

    test "a validation failure reports variable keys to Sentry and logs, never values" do
      Sentry.Test.setup_sentry()

      args =
        @valid_args
        |> Map.put("transactional_id", "unknownTemplate")
        |> put_in(["data_variables", "SECRET_LINK"], "https://example.com/secret-value")

      log =
        capture_log(fn ->
          assert {:cancel, {:validation, _}} = Worker.perform(job(args))
        end)

      refute log =~ "secret-value"
      refute log =~ "https://example.com/invite"

      assert [%Sentry.Event{extra: extra}] = Sentry.Test.pop_sentry_reports()
      refute inspect(extra) =~ "secret-value"
      refute inspect(extra) =~ "https://example.com/invite"

      assert Enum.sort(extra.args.data_variable_keys) ==
               ["INVITATION_LINK", "INVITEE_FIRST_NAME", "SECRET_LINK"]
    end
  end

  defp stub_delivery(result) do
    Application.put_env(:dhc, Dhc.Email.Mailer,
      adapter: Dhc.Email.AdapterStub,
      stub_result: result
    )
  end
end
