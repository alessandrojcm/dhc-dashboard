defmodule Dhc.E2EOnboardingFinalizer do
  @moduledoc false

  alias Dhc.Invitations

  def interrupt!(attempt_id) do
    attempts = Application.get_env(:dhc, :e2e_interrupted_onboarding_attempts, MapSet.new())

    Application.put_env(
      :dhc,
      :e2e_interrupted_onboarding_attempts,
      MapSet.put(attempts, attempt_id)
    )
  end

  def reset! do
    Application.delete_env(:dhc, :e2e_interrupted_onboarding_attempts)
  end

  def clear!(attempt_id) do
    attempts = Application.get_env(:dhc, :e2e_interrupted_onboarding_attempts, MapSet.new())

    Application.put_env(
      :dhc,
      :e2e_interrupted_onboarding_attempts,
      MapSet.delete(attempts, attempt_id)
    )
  end

  def convert_with_discord(
        invitation_id,
        attempt_id,
        continuation_id,
        next_of_kin_name,
        next_of_kin_phone,
        customer_id,
        operation_token
      ) do
    attempts = Application.get_env(:dhc, :e2e_interrupted_onboarding_attempts, MapSet.new())

    if MapSet.member?(attempts, attempt_id) do
      clear!(attempt_id)
      {:error, :e2e_interrupted_finalization}
    else
      Invitations.convert_with_discord(
        invitation_id,
        attempt_id,
        continuation_id,
        next_of_kin_name,
        next_of_kin_phone,
        customer_id,
        operation_token
      )
    end
  end
end
