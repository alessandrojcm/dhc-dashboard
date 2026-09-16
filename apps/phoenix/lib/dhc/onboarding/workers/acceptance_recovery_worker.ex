defmodule Dhc.Onboarding.Workers.AcceptanceRecoveryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :invitations,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Dhc.Onboarding.Acceptance

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_id" => attempt_id}}) do
    case Acceptance.recover(attempt_id) do
      {:ok, _view} -> :ok
      :discard -> {:cancel, :attempt_not_found}
      {:error, :operation_in_progress} -> {:snooze, 30}
      {:error, :payment_not_started} -> {:cancel, :payment_not_started}
      # Attempts predating the Discord continuation model carry no Continuation
      # to lock; they cannot be progressed by this path.
      {:error, :legacy_attempt} -> {:cancel, :legacy_attempt}
      # A misconfigured tier coupon stays broken until an operator fixes the
      # configuration; retrying cannot succeed, so discard remaining attempts.
      {:error, :tier_coupon_not_configured} -> {:cancel, :tier_coupon_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end
end
