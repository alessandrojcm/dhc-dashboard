defmodule Dhc.Onboarding.Acceptance.View do
  @moduledoc false

  # The closed safe-view contract returned by every browser-facing operation of
  # `Dhc.Onboarding.Acceptance`. Views carry no attempt ids, operation tokens,
  # confirmation tokens, provider subjects, idempotency keys, or raw payment
  # state; the `state` discriminator is the only thing the browser branches on.

  alias Dhc.Onboarding.Acceptance.Locked

  @type t ::
          %{state: String.t()}
          | %{state: String.t(), expires_at: DateTime.t()}
          | %{state: String.t(), invitation_email: String.t()}
          | %{state: String.t(), invitation_email: String.t(), discord: map()}
          | %{state: String.t(), complimentary: boolean()}
          | %{state: String.t(), discord_verified: true, retry_allowed: boolean()}

  @restart %{state: "restartVerification"}

  @spec restart() :: t()
  def restart, do: @restart

  @doc "Projects a live or terminal Continuation that has not yet reached payment."
  @spec continuation(map(), map()) :: t()
  def continuation(%{status: "verified"} = continuation, invitation) do
    %{
      state: "discordVerified",
      invitation_email: invitation.email,
      discord: Map.take(continuation.display_metadata, ["username", "avatarUrl"])
    }
  end

  def continuation(%{status: "collision"}, _invitation), do: %{state: "discordCollision"}
  def continuation(%{status: "failed"}, _invitation), do: %{state: "discordUnavailable"}

  def continuation(continuation, _invitation),
    do: %{state: "awaiting_oauth", expires_at: continuation.expires_at}

  @doc "Projects an Attempt that owns (or has completed) payment."
  @spec attempt(map(), map()) :: t()
  def attempt(%{status: "completed"}, invitation), do: accepted(invitation)

  def attempt(%{status: "processing"} = attempt, invitation) do
    if Locked.payment_ready?(attempt),
      do: %{state: "paymentReady", complimentary: invitation.pricing_tier == "coach"},
      else: @restart
  end

  def attempt(%{status: "payment_pending", stripe_state: stripe_state} = attempt, _invitation) do
    {state, retry_allowed} =
      case Map.get(stripe_state, "payment_state") do
        "needs_action" -> {"paymentNeedsAction", true}
        "terminal" -> {"paymentTerminal", false}
        _ -> {"paymentPending", Locked.retry_allowed?(attempt)}
      end

    %{state: state, discord_verified: true, retry_allowed: retry_allowed}
  end

  def attempt(%{status: "provisioned"} = attempt, _invitation) do
    %{
      state: "paymentPending",
      discord_verified: true,
      retry_allowed: Locked.retry_allowed?(attempt)
    }
  end

  def attempt(_attempt, _invitation), do: @restart

  @spec accepted(map()) :: t()
  def accepted(invitation), do: %{state: "accepted", invitation_email: invitation.email}

  @doc """
  Projects the whole locked graph for a read. Returns `:restart` when the
  session cannot continue and the browser must verify credentials again.
  """
  @spec current(Locked.t()) :: {:ok, t()} | :restart
  def current(%Locked{
        continuation: %{status: "collision"} = continuation,
        invitation: invitation
      }),
      do: {:ok, continuation(continuation, invitation)}

  def current(%Locked{
        continuation: %{status: "failed"} = continuation,
        invitation: invitation,
        attempt: %{last_error: "discord_failed"}
      }),
      do: {:ok, continuation(continuation, invitation)}

  def current(%Locked{continuation: %{status: "failed"}}), do: {:ok, @restart}

  def current(%Locked{
        invitation: %{status: "accepted"} = invitation,
        attempt: %{status: "completed"}
      }),
      do: {:ok, accepted(invitation)}

  def current(%Locked{
        continuation: %{status: "verified"},
        invitation: invitation,
        attempt: attempt
      })
      when attempt.status in ["payment_pending", "provisioned"],
      do: {:ok, attempt(attempt, invitation)}

  def current(%Locked{continuation: %{status: "verified"} = continuation} = locked) do
    cond do
      Locked.payment_ready?(locked.attempt) -> {:ok, attempt(locked.attempt, locked.invitation)}
      active_processing?(locked) -> {:ok, continuation(continuation, locked.invitation)}
      true -> :restart
    end
  end

  def current(%Locked{continuation: %{status: "awaiting_oauth"} = continuation} = locked) do
    if active_processing?(locked),
      do: {:ok, continuation(continuation, locked.invitation)},
      else: :restart
  end

  def current(%Locked{}), do: :restart

  defp active_processing?(%Locked{attempt: attempt} = locked) do
    attempt.status == "processing" and Locked.invitation_unexpired?(locked) and
      Locked.continuation_unexpired?(locked)
  end
end
