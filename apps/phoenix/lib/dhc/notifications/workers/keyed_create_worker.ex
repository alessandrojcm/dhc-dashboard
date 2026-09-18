defmodule Dhc.Notifications.Workers.KeyedCreateWorker do
  @moduledoc """
  ALE-298: durable, retried `create_keyed/3` after a loan command commits.

  Loan transitions are not notification-atomic: the command writes first and
  the HTTP layer only enqueues this job. A failed enqueue is a 500 before the
  client is told the transition succeeded. A failed `create_keyed/3` inside
  the job is retried; the key makes a repeat a no-op rather than a second
  unread row.

  Args are `%{"principal_ids" => [...], "key" => key, "body" => body}` — one
  logical event, many recipients. `unique` on `key` collapses a double
  enqueue of the same event while the first job is still incomplete.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:key], states: :incomplete]

  alias Dhc.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"principal_ids" => ids, "key" => key, "body" => body}})
      when is_list(ids) and is_binary(key) and is_binary(body) do
    Enum.reduce_while(ids, :ok, fn principal_id, :ok ->
      case create_keyed(principal_id, key, body) do
        {:ok, _created_or_already} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  # Tests inject a failing create via `:keyed_notification_create`, matching
  # the `:notification_broadcaster` / `:web_push_sender` seams.
  defp create_keyed(principal_id, key, body) do
    :dhc
    |> Application.get_env(:keyed_notification_create, &Notifications.create_keyed/3)
    |> then(& &1.(principal_id, key, body))
  end
end
