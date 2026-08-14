defmodule Dhc.E2EOnboardingFinalizer do
  @moduledoc false

  alias Dhc.Invitations

  def interrupt_next! do
    Application.put_env(:dhc, :e2e_interrupt_next_onboarding_finalization, true)
  end

  def reset! do
    Application.delete_env(:dhc, :e2e_interrupt_next_onboarding_finalization)
  end

  def convert_with_discord(
        invitation_id,
        attempt_id,
        continuation_id,
        next_of_kin_name,
        next_of_kin_phone,
        customer_id
      ) do
    if Application.get_env(:dhc, :e2e_interrupt_next_onboarding_finalization, false) do
      reset!()
      {:error, :e2e_interrupted_finalization}
    else
      Invitations.convert_with_discord(
        invitation_id,
        attempt_id,
        continuation_id,
        next_of_kin_name,
        next_of_kin_phone,
        customer_id
      )
    end
  end
end
