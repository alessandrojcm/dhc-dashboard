defmodule Dhc.Onboarding.SafeView do
  @moduledoc false

  alias Dhc.Onboarding.AttemptState

  def continuation_state(%{status: "verified"} = continuation, invitation) do
    %{
      state: "discordVerified",
      invitation_email: invitation.email,
      discord: Map.take(continuation.display_metadata, ["username", "avatarUrl"])
    }
  end

  def continuation_state(%{status: "collision"}, _invitation),
    do: %{state: "discordCollision"}

  def continuation_state(%{status: "failed"}, _invitation),
    do: %{state: "discordUnavailable"}

  def continuation_state(continuation, _invitation) do
    %{state: "awaiting_oauth", expires_at: continuation.expires_at}
  end

  def acceptance_state(continuation, invitation, attempt, now) do
    cond do
      continuation.status == "collision" ->
        {:ok, continuation_state(continuation, invitation)}

      continuation.status == "failed" and attempt.last_error == "discord_failed" ->
        {:ok, continuation_state(continuation, invitation)}

      continuation.status == "failed" ->
        {:ok, %{state: "restartVerification"}}

      attempt.status == "completed" and invitation.status == "accepted" ->
        {:ok, %{state: "accepted", invitation_email: invitation.email}}

      attempt.status == "payment_pending" and continuation.status == "verified" ->
        {:ok, attempt_state(attempt, invitation)}

      attempt.status == "provisioned" and continuation.status == "verified" ->
        {:ok, attempt_state(attempt, invitation)}

      AttemptState.payment_ready?(attempt) and continuation.status == "verified" ->
        {:ok, attempt_state(attempt, invitation)}

      attempt.status == "processing" and continuation.status in ["awaiting_oauth", "verified"] and
        DateTime.compare(invitation.expires_at, now) == :gt and
          DateTime.compare(continuation.expires_at, now) == :gt ->
        {:ok, continuation_state(continuation, invitation)}

      true ->
        {:error, :restart_verification}
    end
  end

  def attempt_state(%{status: "completed"}, invitation),
    do: %{state: "accepted", invitation_email: invitation.email}

  def attempt_state(%{status: "processing"} = attempt, _invitation) do
    if AttemptState.payment_ready?(attempt),
      do: %{state: "paymentReady"},
      else: %{state: "restartVerification"}
  end

  def attempt_state(
        %{status: "payment_pending", stripe_state: stripe_state} = attempt,
        _invitation
      ) do
    {state, retry_allowed} =
      case Map.get(stripe_state, "payment_state") do
        "needs_action" -> {"paymentNeedsAction", true}
        "terminal" -> {"paymentTerminal", false}
        _ -> {"paymentPending", AttemptState.retry_allowed?(attempt)}
      end

    %{state: state, discord_verified: true, retry_allowed: retry_allowed}
  end

  def attempt_state(%{status: "provisioned"} = attempt, _invitation) do
    %{
      state: "paymentPending",
      discord_verified: true,
      retry_allowed: AttemptState.retry_allowed?(attempt)
    }
  end

  def attempt_state(_attempt, _invitation), do: %{state: "restartVerification"}
end
