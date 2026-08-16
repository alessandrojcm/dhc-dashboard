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

  def acceptance_state(%{status: "collision"} = continuation, invitation, _attempt, _now),
    do: {:ok, continuation_state(continuation, invitation)}

  def acceptance_state(
        %{status: "failed"} = continuation,
        invitation,
        %{last_error: "discord_failed"},
        _now
      ),
      do: {:ok, continuation_state(continuation, invitation)}

  def acceptance_state(%{status: "failed"}, _invitation, _attempt, _now),
    do: {:ok, %{state: "restartVerification"}}

  def acceptance_state(
        _continuation,
        %{status: "accepted"} = invitation,
        %{status: "completed"},
        _now
      ),
      do: {:ok, %{state: "accepted", invitation_email: invitation.email}}

  def acceptance_state(
        %{status: "verified"},
        invitation,
        %{status: status} = attempt,
        _now
      )
      when status in ["payment_pending", "provisioned"],
      do: {:ok, attempt_state(attempt, invitation)}

  def acceptance_state(%{status: "verified"} = continuation, invitation, attempt, now) do
    cond do
      AttemptState.payment_ready?(attempt) ->
        {:ok, attempt_state(attempt, invitation)}

      active_processing?(continuation, invitation, attempt, now) ->
        {:ok, continuation_state(continuation, invitation)}

      true ->
        {:error, :restart_verification}
    end
  end

  def acceptance_state(%{status: "awaiting_oauth"} = continuation, invitation, attempt, now) do
    if active_processing?(continuation, invitation, attempt, now),
      do: {:ok, continuation_state(continuation, invitation)},
      else: {:error, :restart_verification}
  end

  def acceptance_state(_continuation, _invitation, _attempt, _now),
    do: {:error, :restart_verification}

  defp active_processing?(continuation, invitation, attempt, now) do
    attempt.status == "processing" and
      DateTime.compare(invitation.expires_at, now) == :gt and
      DateTime.compare(continuation.expires_at, now) == :gt
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
