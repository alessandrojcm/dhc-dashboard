defmodule Dhc.TrainingAnnouncements.Delivery do
  @moduledoc "Frozen Discord progression. Calls happen after commit; conditional writes fence each checkpoint."
  import Ecto.Query
  alias Dhc.Discord
  alias Dhc.Discord.ApiError
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence

  # Called only inside Store.with_current/2, alongside scheduling the next slot.
  def freeze(announcement, occurrence, channel, copy, now) do
    attrs = %{
      id: Ecto.UUID.generate(),
      subject: "occurrence",
      announcement_id: announcement.id,
      occurrence_date: occurrence.date,
      post_time: announcement.post_time,
      kind: occurrence.kind,
      mention_everyone: occurrence.mention_everyone,
      title_source: occurrence.title,
      message_source: occurrence.message,
      rendered_message: copy.rendered_message,
      thread_name: copy.thread_name,
      channel_id: channel,
      applied_suppression_id: occurrence.applied_suppression_id,
      applied_override_id: occurrence.applied_override_id,
      state: "frozen",
      resolved_outcome: to_string(occurrence.outcome),
      precedence_chain: Enum.map(occurrence.chain, &to_string/1),
      frozen_at: now,
      created_at: now,
      updated_at: now
    }

    case Repo.insert_all(Evidence, [attrs], on_conflict: :nothing, returning: true) do
      {1, [delivery]} ->
        if is_nil(announcement.first_attempted_at) do
          announcement |> Ecto.Changeset.change(first_attempted_at: now) |> Repo.update!()
        end

        delivery

      {0, []} ->
        nil
    end
  end

  def for_occurrence(id, date) do
    Repo.one(from(d in Evidence, where: d.announcement_id == ^id and d.occurrence_date == ^date))
  end

  def progress(delivery, job, clock)
  def progress(nil, _job, _clock), do: :ok

  def progress(delivery, job, clock) do
    # Single-node live-call coordination, not durable workflow authority. The
    # process-owned lock disappears on death. Without it a duplicate retry
    # could confuse a live posting checkpoint with a dead worker. The row's
    # uniqueness and conditional checkpoints remain the durable duplicate fence.
    lock = {{__MODULE__, delivery.id}, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        do_progress(Repo.get(Evidence, delivery.id), job, clock)
      after
        :global.del_lock(lock, [node()])
      end
    else
      # A date-owned holiday recovery driver must remain pending while a live
      # roll-call worker owns the call, rather than disappear before a crash.
      if delivery.subject == "holiday", do: {:snooze, 30}, else: :ok
    end
  end

  defp do_progress(%{state: "frozen"} = delivery, job, clock) do
    now = clock.()

    cond do
      Date.compare(send_date(delivery), ClubCalendar.on_date(now)) == :lt ->
        checkpoint(delivery, %{state: "missed", reason: "late", concluded_at: now})
        :ok

      job.attempt >= job.max_attempts ->
        conclude(
          delivery,
          "blocked",
          "unknown",
          "Retry budget exhausted before message submission",
          clock
        )

      true ->
        case checkpoint(delivery, %{
               state: "posting_message",
               posting_started_at: delivery.posting_started_at || now
             }) do
          nil -> :ok
          claimed -> post_message(claimed, job, clock)
        end
    end
  end

  defp do_progress(%{state: "message_posted", subject: "holiday"} = delivery, _job, clock) do
    checkpoint(delivery, %{state: "delivered", concluded_at: clock.()})
    :ok
  end

  defp do_progress(%{state: "message_posted"} = delivery, job, clock) do
    if job.attempt >= job.max_attempts do
      conclude(
        delivery,
        "thread_failed",
        "unknown",
        "Retry budget exhausted before thread submission",
        clock
      )
    else
      create_thread(delivery, job, clock)
    end
  end

  defp do_progress(%{state: "posting_message"} = delivery, _job, clock),
    do:
      conclude(
        delivery,
        "message_uncertain",
        "worker_lost",
        "Worker lost after message submission checkpoint",
        clock
      )

  defp do_progress(%{state: "creating_thread"} = delivery, _job, clock) do
    detail = "Worker lost after thread submission checkpoint"

    case checkpoint(delivery, %{last_thread_error: detail}) do
      nil -> :ok
      updated -> conclude(updated, "thread_failed", "worker_lost", detail, clock)
    end
  end

  defp do_progress(_delivery, _job, _clock), do: :ok

  defp post_message(delivery, job, clock) do
    params = %{
      content: delivery.rendered_message,
      allowed_mentions: %{parse: if(delivery.mention_everyone, do: ["everyone"], else: [])},
      nonce: nonce(delivery)
    }

    case Discord.create_message(delivery.channel_id, params) do
      {:ok, %{message_id: id}} ->
        delivery
        |> checkpoint(%{
          state: "message_posted",
          discord_message_id: id,
          message_posted_at: clock.()
        })
        |> do_progress(job, clock)

      {:error, {:blocked, error}} ->
        conclude(delivery, "blocked", reason(error), detail(error), clock)

      {:error, {:uncertain, error}} ->
        conclude(delivery, "message_uncertain", reason(error), detail(error), clock)

      {:error, {:retry, error}} ->
        if job.attempt + 1 < job.max_attempts do
          checkpoint(delivery, %{state: "frozen", error_detail: detail(error)})
          {:error, error}
        else
          conclude(delivery, "blocked", reason(error), detail(error), clock)
        end
    end
  end

  defp create_thread(delivery, job, clock) do
    case checkpoint(delivery, %{
           state: "creating_thread",
           thread_attempts: delivery.thread_attempts + 1
         }) do
      nil ->
        :ok

      claimed ->
        result =
          Discord.create_thread_from_message(claimed.channel_id, claimed.discord_message_id, %{
            name: claimed.thread_name,
            auto_archive_duration: 1440
          })

        case result do
          {:ok, %{thread_id: id}} ->
            checkpoint(claimed, %{
              state: "delivered",
              discord_thread_id: id,
              thread_created_at: clock.(),
              concluded_at: clock.()
            })

            :ok

          {:error, {classification, error}} ->
            thread_failure(claimed, classification, error, job, clock)
        end
    end
  end

  defp thread_failure(delivery, classification, error, job, clock) do
    # An ambiguous thread result is not safe to retry either. The message stays.
    updated = checkpoint(delivery, %{last_thread_error: detail(error)})

    cond do
      is_nil(updated) ->
        :ok

      classification != :uncertain and job.attempt + 1 < job.max_attempts ->
        checkpoint(updated, %{state: "message_posted"})
        {:error, error}

      true ->
        conclude(updated, "thread_failed", reason(error), detail(error), clock)
    end
  end

  defp checkpoint(delivery, attrs) do
    query =
      from(d in Evidence,
        where:
          d.id == ^delivery.id and d.state == ^delivery.state and
            d.thread_attempts == ^delivery.thread_attempts,
        select: d
      )

    case Repo.update_all(query, set: Map.to_list(Map.put(attrs, :updated_at, DateTime.utc_now()))) do
      {1, [updated]} -> updated
      {0, []} -> nil
    end
  end

  defp nonce(delivery) do
    # Discord nonces are limited to 25 characters; UUID-derived, stable per row.
    binary_part(Base.encode16(:crypto.hash(:sha256, delivery.id), case: :lower), 0, 25)
  end

  defp conclude(delivery, state, reason, detail, clock) do
    case checkpoint(delivery, %{
           state: state,
           reason: reason,
           error_detail: detail,
           concluded_at: clock.()
         }) do
      nil ->
        :ok

      terminal ->
        report_failure(terminal)
        :ok
    end
  end

  def report_failure(%{state: state} = delivery)
      when state in ["blocked", "message_uncertain", "thread_failed"] do
    Sentry.capture_message("Training Announcement delivery #{state}",
      level: :error,
      extra: %{
        delivery_id: delivery.id,
        announcement_id: delivery.announcement_id,
        occurrence_date: Date.to_iso8601(send_date(delivery)),
        reason: delivery.reason
      }
    )
  end

  def report_failure(_delivery), do: :ok

  defp send_date(%{subject: "holiday", holiday_date: date, phase: "day_before"}),
    do: Date.add(date, -1)

  defp send_date(%{subject: "holiday", holiday_date: date}), do: date
  defp send_date(delivery), do: delivery.occurrence_date

  defp reason(%ApiError{status: 403}), do: "permission"
  defp reason(%ApiError{status: 404}), do: "unknown_channel"
  defp reason(%ApiError{status: 400}), do: "payload_rejected"
  defp reason(%ApiError{status: 408}), do: "timeout"
  defp reason(%ApiError{details: :timeout}), do: "timeout"
  defp reason(%ApiError{status: status}) when status >= 500, do: "server_error"
  defp reason(_error), do: "unknown"

  defp detail(error), do: String.slice("#{error.code}: #{error.message}", 0, 500)
end
