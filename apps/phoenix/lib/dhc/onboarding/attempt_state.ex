defmodule Dhc.Onboarding.AttemptState do
  @moduledoc false

  def pre_oauth?(attempt) do
    attempt.status == "processing" and attempt.acceptance_data == %{} and
      attempt.stripe_customer_id in [nil, ""] and attempt.stripe_state == %{}
  end

  def payment_ready?(attempt) do
    attempt.status == "processing" and
      present?(Map.get(attempt.acceptance_data, "continuation_id"))
  end

  def retry_allowed?(attempt) do
    attempt.status in ["payment_pending", "provisioned"] and not is_nil(attempt.last_error) and
      not lease_active?(attempt)
  end

  def lease_active?(%{operation_token: nil}), do: false
  def lease_active?(%{operation_started_at: nil}), do: false

  def lease_active?(attempt) do
    DateTime.compare(
      attempt.operation_started_at,
      DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:second)
    ) == :gt
  end

  def discord_bound?(attempt) do
    present?(Map.get(attempt.acceptance_data, "continuation_id")) or
      present?(Map.get(attempt.acceptance_data, "discord_continuation_id"))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
