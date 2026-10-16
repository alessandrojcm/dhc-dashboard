defmodule Dhc.BeginnersWorkshops.Workers.ReplyWorker do
  @moduledoc """
  ALE-409: forwards one Intake Reply to the club inbox.

  A driver only: it turns its one argument, the Resend email id, into
  `Dhc.BeginnersWorkshops.IntakeReplies.forward/2`, telling it whether this
  is the last attempt (when a reply that still cannot be read is forwarded
  as the banner alone, and a forward that cannot be sent raises the
  coordinator alert). Unique on its argument, so a redelivered webhook never
  queues a second job.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], states: :all]

  alias Dhc.BeginnersWorkshops.IntakeReplies

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"resend_email_id" => id}} = job) when is_binary(id) do
    case IntakeReplies.forward(id, final: job.attempt >= job.max_attempts) do
      {:ok, _outcome} -> :ok
      {:error, :reply_not_found} -> {:discard, :reply_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}
end
