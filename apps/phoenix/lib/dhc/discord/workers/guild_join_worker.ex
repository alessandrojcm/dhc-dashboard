defmodule Dhc.Discord.Workers.GuildJoinWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :discord,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  require Logger

  alias Dhc.Discord
  alias Dhc.Discord.ApiError
  alias Dhc.Notifications

  @denied_statuses [401, 403]

  # A terminal outcome is one the job never retries: a denial returns `:ok`
  # after zeroizing, and an exhausted job is discarded. Oban's Sentry
  # integration reports only job *exceptions* (plus the cron plugin), so
  # neither of those return values reaches Sentry on its own — and where Oban
  # does report, its context is job args, which carry the grant id and nothing
  # about the member behind it. Every terminal outcome therefore emits all
  # three signals — a Sentry capture at the outcome's level, a structured log,
  # and a keyed member notification — so a paying member who never lands in the
  # guild is visible without waiting for a complaint. Retry policy
  # (max_attempts: 5) and zeroize semantics are unchanged.
  @terminal_outcomes %{
    denied: %{
      level: :warning,
      message: "Discord guild join denied",
      reason: "discord_authorization_denied",
      body:
        "We couldn't add you to the Discord server automatically. " <>
          "Please contact support and we'll send you a fresh invite."
    },
    exhausted: %{
      level: :error,
      message: "Discord guild join retries exhausted",
      reason: nil,
      body:
        "We tried several times to add you to the Discord server but couldn't " <>
          "reach it. Please contact support and we'll get you added."
    }
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"grant_id" => grant_id}} = job) do
    case Discord.prepare_guild_join(grant_id) do
      {:ok, join} -> add_member(join, job)
      {:terminal, _reason} -> :ok
      {:error, reason} -> retry_or_report(job, grant_id, nil, reason)
    end
  end

  defp add_member(join, job) do
    case Discord.add_guild_member(join.user_id, join.access_token, join.nickname) do
      {:ok, outcome} when outcome in [:added, :already_member] ->
        zeroize(join.grant)

      {:error, %ApiError{status: status}} when status in @denied_statuses ->
        zeroize_and_report(job, join.grant, status)

      {:error, reason} ->
        retry_or_report(job, join.grant.id, join.grant.attempt_id, reason)
    end
  end

  defp zeroize(grant) do
    case Discord.zeroize_join_grant(grant) do
      {:ok, _grant} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Zeroize before reporting, so the token is unrecoverable on every path that
  # reaches `emit/6` — nothing here can carry it, before or after.
  #
  # A zeroization failure is returned so Oban retries the write, but the denial
  # is reported anyway: Discord's answer is terminal, so waiting for a clean
  # zeroize to report it is how a paying member ends up unjoined with no trace
  # of why. The notification is keyed, so reporting on both the failing attempt
  # and its retry costs the member nothing.
  defp zeroize_and_report(job, grant, status) do
    zeroized = zeroize(grant)
    emit(job, :denied, grant.id, grant.attempt_id, status)
    zeroized
  end

  # Earlier attempts are ordinary retries and stay quiet; only the final attempt
  # reports, because once Oban discards the job the member would otherwise wait
  # in silence with the reason recorded nowhere but `oban_jobs.errors`.
  defp retry_or_report(job, grant_id, attempt_id, reason) do
    if job.attempt >= job.max_attempts do
      emit(job, :exhausted, grant_id, attempt_id, discord_status(reason), safe_reason(reason))
    end

    {:error, reason}
  end

  # One terminal signal per outcome, emitted from one place so the log, the
  # Sentry event, and the member notification cannot drift apart. Every field is
  # an identifier: the access token is zeroized before this runs, and the
  # Discord subject, nickname, and contact details never appear.
  #
  # The capture is deliberately additional to the log, matching every other
  # worker here (`Dhc.Email.Worker`, `Dhc.Invitations.BulkInviteWorker`): the
  # log is a searchable record, the capture is the grouped Sentry issue a
  # responder actually sees. On the `:error` outcome `Sentry.LoggerHandler` also
  # forwards the log, which is redundancy rather than a second root cause.
  defp emit(job, outcome, grant_id, attempt_id, status, reason \\ nil) do
    spec = terminal_outcome(outcome)
    context = join_context(grant_id)

    fields = %{
      grant_id: grant_id,
      attempt_id: attempt_id,
      invitation_id: context[:invitation_id],
      status: status,
      reason: reason || spec.reason,
      oban_job_id: job.id,
      oban_attempt: job.attempt
    }

    Logger.log(spec.level, "[guild-join-worker] #{spec.message}", Map.to_list(fields))

    Sentry.capture_message(spec.message,
      level: spec.level,
      extra: fields
    )

    notify_member(grant_id, context, outcome)
  end

  defp terminal_outcome(outcome), do: Map.fetch!(@terminal_outcomes, outcome)

  defp join_context(grant_id) do
    case Discord.guild_join_context(grant_id) do
      {:ok, context} -> context
      {:error, _not_found} -> %{}
    end
  end

  # Keyed on the grant, so a terminal signal that repeats — a re-executed final
  # attempt, a manual replay — is a no-op rather than a second unread row.
  # Best-effort by design: a notification failure must not turn a terminal join
  # outcome into a job error and re-run the whole join.
  defp notify_member(grant_id, context, outcome) do
    if principal_id = context[:principal_id] do
      create_notification(principal_id, grant_id, outcome, terminal_outcome(outcome).body)
    else
      Logger.warning(
        "[guild-join-worker] Guild join member unknown; #{outcome} notification skipped",
        grant_id: grant_id
      )
    end
  end

  defp create_notification(principal_id, grant_id, outcome, body) do
    case Notifications.create_keyed(
           principal_id,
           "discord:guild-join:#{grant_id}:#{outcome}",
           body
         ) do
      {:ok, _created_or_already} ->
        :ok

      {:error, reason} ->
        Logger.warning("[guild-join-worker] Guild join notification failed",
          grant_id: grant_id,
          reason: safe_reason(reason)
        )

        :ok
    end
  end

  # Never `inspect/1` a failure into an observability payload: a changeset from
  # zeroization or notification creation carries whole rows, and an unvetted
  # provider error may carry personal data. Named failures are named — the HTTP
  # status travels in its own field — and anything else is described by shape
  # alone.
  defp safe_reason(%ApiError{}), do: "discord_api_error"

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({type, _detail}) when is_atom(type), do: Atom.to_string(type)
  defp safe_reason(_reason), do: "unclassified"

  defp discord_status(%ApiError{status: status}), do: status
  defp discord_status(_reason), do: nil
end
