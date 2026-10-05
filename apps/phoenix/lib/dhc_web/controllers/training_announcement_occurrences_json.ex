defmodule DhcWeb.TrainingAnnouncementOccurrencesJSON do
  def index(%{result: items}), do: %{data: Enum.map(items, &item/1)}
  def show(%{result: result}), do: %{data: item(result)}

  defp item(item) do
    %{
      subject: item.subject,
      date: item.date,
      announcementId: item.announcement_id,
      appliedSuppressionId: item.applied_suppression_id,
      appliedOverrideId: item.applied_override_id,
      holidayDate: item.holiday_date,
      phase: item.phase,
      postTime: item.post_time,
      kind: item.kind,
      outcome: item.outcome,
      chain: item.chain,
      decidedBy: List.last(item.chain),
      titleSource: item.title_source,
      messageSource: item.message_source,
      mentionEveryone: item.mention_everyone,
      renderedMessage: item.rendered_message,
      threadName: item.thread_name,
      readOnly: item.read_only,
      renderErrors: item.render_errors,
      delivery: delivery(item.delivery)
    }
  end

  defp delivery(nil), do: nil

  defp delivery(row) do
    %{
      id: row.id,
      state: row.state,
      reason: row.reason,
      frozenAt: row.frozen_at,
      postingStartedAt: row.posting_started_at,
      messagePostedAt: row.message_posted_at,
      threadCreatedAt: row.thread_created_at,
      concludedAt: row.concluded_at,
      discordMessageId: row.discord_message_id,
      discordThreadId: row.discord_thread_id,
      permalink: row.permalink,
      errorDetail: row.error_detail,
      threadAttempts: row.thread_attempts,
      lastThreadError: row.last_thread_error,
      appliedSuppressionId: row.applied_suppression_id,
      appliedOverrideId: row.applied_override_id
    }
  end
end
