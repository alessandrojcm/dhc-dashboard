defmodule Dhc.BeginnersWorkshops.Commands.Replies do
  @moduledoc """
  Intake Reply commands (ALE-409, ADR 0030).
  `Dhc.BeginnersWorkshops.Commands` authorizes the actor and routes here.

    * `{:alert_reply_waiting, resend_email_id}` (`:system`) — an Intake
      Reply could not be forwarded to the club inbox, even as the banner
      alone: a keyed coordinator alert (`Commands.CoordinatorAlerts`, key
      `beginners-intake-reply:<resend email id>:forward-failed`) says a reply
      is waiting in Resend. It locks nothing: an Intake Reply row is not a
      lock level, and the alert is keyed, so a repeat creates nothing.

  ## Cross-family calls

  None: the alert is `Commands.CoordinatorAlerts`' and its text
  `Commands.NotificationCopy`'.
  """

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [signal_after_commit: 1, transact: 1]

  import Dhc.BeginnersWorkshops.Commands.CoordinatorAlerts, only: [alert: 2]

  alias Dhc.BeginnersWorkshops.Commands.NotificationCopy
  alias Dhc.Resend.Receiving

  @doc false
  def run(:system, {:alert_reply_waiting, resend_email_id}, _clock)
      when is_binary(resend_email_id) do
    if Receiving.valid_id?(resend_email_id),
      do: resend_email_id |> alert_reply_waiting() |> signal_after_commit(),
      else: {:error, :invalid_payload}
  end

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  defp alert_reply_waiting(resend_email_id) do
    key = "beginners-intake-reply:#{resend_email_id}:forward-failed"

    transact(fn ->
      with {:ok, created} <- alert(key, NotificationCopy.reply_waiting(resend_email_id)),
           do: {:ok, {%{outcome: :alerted}, created}}
    end)
  end
end
