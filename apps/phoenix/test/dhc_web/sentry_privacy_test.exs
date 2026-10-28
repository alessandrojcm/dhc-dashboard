defmodule DhcWeb.SentryPrivacyTest do
  use ExUnit.Case, async: true

  test "the configured Sentry hook removes email job content from automatic Oban reports" do
    job = %Oban.Job{
      id: 42,
      worker: "Dhc.Email.Worker",
      queue: "emails",
      attempt: 5,
      max_attempts: 5,
      args: %{
        "email" => "private@example.test",
        "transactional_id" => "beginnersWorkshopAction",
        "data_variables" => %{"MESSAGE_HTML" => "private email body"},
        "sealed_data_variables" => "private ciphertext"
      }
    }

    event =
      Sentry.Event.transform_exception(
        Oban.PerformError.exception({Dhc.Email.Worker, {:error, {429, "private provider body"}}}),
        extra: Map.take(job, [:args, :id, :attempt, :max_attempts, :worker, :queue]),
        tags: %{oban_worker: job.worker},
        integration_meta: %{oban: %{job: job}}
      )

    {module, function} = Application.fetch_env!(:sentry, :before_send)
    redacted = apply(module, function, [event])
    refute inspect(redacted) =~ "private"
    assert redacted.extra.id == 42
    assert redacted.extra.args.transactional_id == "beginnersWorkshopAction"
    assert redacted.extra.provider_status == 429
  end

  test "invalid variable shapes do not break the privacy hook or hide validation failures" do
    event =
      Sentry.Event.create_event(
        message: "Invalid email job args",
        tags: %{oban_worker: "Dhc.Email.Worker"},
        extra: %{args: %{"data_variables" => "private body", "email" => "private@example.test"}}
      )

    assert %Sentry.Event{} = redacted = DhcWeb.SentryPrivacy.before_send(event)
    refute inspect(redacted) =~ "private"
  end

  test "ordinary email retries stay quiet, but exhausted jobs remain observable" do
    Sentry.Test.setup_sentry()

    job = %Oban.Job{
      id: 7,
      worker: "Dhc.Email.Worker",
      queue: "emails",
      attempt: 1,
      max_attempts: 5,
      args: %{"email" => "private@example.test"}
    }

    reason = Oban.PerformError.exception({Dhc.Email.Worker, {:error, {429, "private body"}}})
    metadata = %{job: job, kind: :error, reason: reason, stacktrace: []}

    Sentry.Integrations.Oban.ErrorReporter.handle_event(
      [:oban, :job, :exception],
      %{},
      metadata,
      []
    )

    assert [] = Sentry.Test.pop_sentry_reports()

    Sentry.Integrations.Oban.ErrorReporter.handle_event(
      [:oban, :job, :exception],
      %{},
      %{metadata | job: %{job | attempt: 5}},
      []
    )

    assert [%Sentry.Event{extra: %{id: 7}} = event] = Sentry.Test.pop_sentry_reports()
    refute inspect(event) =~ "private"
  end

  test "actual Oban reports for nested offer-round args scrub errors, throws and exits" do
    Sentry.Test.setup_sentry(dedup_events: false)

    job = %Oban.Job{
      id: 99,
      worker: "Dhc.Email.OfferRoundWorker",
      queue: "emails",
      attempt: 1,
      max_attempts: 5,
      args: %{
        "round_id" => "safe-round",
        "chunk" => 0,
        "count" => 2,
        "sealed_envelopes" => "private ciphertext",
        "envelopes" => [
          %{
            "email" => "private@example.test",
            "reply_to" => "private@reply.example.test",
            "body" => "private message"
          }
        ]
      }
    }

    for kind <- [:error, :throw, :exit] do
      reason =
        if kind == :error, do: RuntimeError.exception("private exception"), else: "private reason"

      Sentry.Integrations.Oban.ErrorReporter.handle_event(
        [:oban, :job, :exception],
        %{},
        %{job: job, kind: kind, reason: reason, stacktrace: []},
        []
      )

      assert [event] = Sentry.Test.pop_sentry_reports()
      refute inspect(event) =~ "private"
      assert event.extra.id == 99
      assert event.extra.args == %{"round_id" => "safe-round", "chunk" => 0, "count" => 2}
    end
  end
end
