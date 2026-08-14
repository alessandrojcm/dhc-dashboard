defmodule Dhc.Onboarding.Workers.AcceptanceRecoveryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :invitations,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Dhc.Onboarding

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => attempt_id}}) do
    case Onboarding.recover_acceptance(attempt_id) do
      :ok -> :ok
      {:ok, _state} -> :ok
      :discard -> :discard
      {:error, _reason} -> {:snooze, 60}
    end
  end
end
