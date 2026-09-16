defmodule Dhc.Onboarding.Acceptance.Locked do
  @moduledoc false

  # The one lock graph for an Invitation Acceptance session.
  #
  # Every authoritative read or write of Continuation, Attempt, Invitation, or
  # Claim rows goes through here so lock acquisition happens in exactly one
  # order (ADR-0017, ADR-0019):
  #
  #   1. advisory `discord/principal/<prospective principal>`
  #   2. advisory `discord/subject/discord/<subject>` for every subject involved
  #   3. row locks: Continuation → Attempt → Invitation → Claims
  #
  # The principal advisory lock serialises all operations on one Invitation, so
  # `open/4` (which starts from an Invitation and may create the Continuation)
  # can safely take Invitation → Attempt → Continuation after the same advisory
  # lock without risking a deadlock against a handle-based operation.
  #
  # Probe reads before the advisory locks discover only identifiers. Every fact
  # that decides a transition is re-read under the locks.

  import Ecto.Query

  alias Dhc.Auth.DiscordSubjectLock
  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo

  @type t :: %__MODULE__{
          invitation: Invitation.t(),
          attempt: InvitationAcceptanceAttempt.t(),
          continuation: InvitationAcceptanceDiscordContinuation.t(),
          claims: [map()],
          now: DateTime.t()
        }

  defstruct [:invitation, :attempt, :continuation, :now, claims: []]

  @recoverable_statuses ["payment_pending", "cleanup_pending", "provisioned"]

  @doc """
  Locks the acceptance rows reachable from a Continuation id.

  `opts[:subjects]` adds Discord subjects to lock besides the Continuation's
  own (the OAuth callback locks the subject it is about to claim).
  """
  @spec by_continuation(Ecto.UUID.t(), DateTime.t(), keyword()) ::
          {:ok, t()} | {:error, :not_found | :inconsistent}
  def by_continuation(continuation_id, now, opts \\ []) do
    with %InvitationAcceptanceDiscordContinuation{} = probe <-
           Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id),
         %Invitation{} = invitation_ref <- Repo.get(Invitation, probe.invitation_id) do
      DiscordSubjectLock.lock_principal!(invitation_ref.prospective_principal_id)
      lock_subjects!(continuation_id, Keyword.get(opts, :subjects, []))
      lock_rows(continuation_id, now)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Locks the acceptance rows for an Attempt through its Continuation.

  Attempts predating the Discord continuation model have no Continuation and
  cannot be locked; they are reported as `:legacy_attempt`.
  """
  @spec by_attempt(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, t()} | {:error, :not_found | :inconsistent | :legacy_attempt}
  def by_attempt(attempt_id, now) do
    case Repo.get(InvitationAcceptanceAttempt, attempt_id) do
      nil ->
        {:error, :not_found}

      attempt_ref ->
        case attempt_continuation_ref(attempt_ref) do
          nil -> {:error, :legacy_attempt}
          continuation_ref -> by_attempt_continuation(continuation_ref.id, attempt_id, now)
        end
    end
  end

  defp by_attempt_continuation(continuation_id, attempt_id, now) do
    case by_continuation(continuation_id, now) do
      {:ok, %__MODULE__{attempt: %{id: ^attempt_id}} = locked} -> {:ok, locked}
      {:ok, _other_attempt} -> {:error, :inconsistent}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Takes the principal advisory lock for an Invitation before `open/4` locks
  Invitation → Attempt → Continuation. Returns `false` when the Invitation does
  not exist.
  """
  @spec lock_invitation_principal!(Ecto.UUID.t()) :: boolean()
  def lock_invitation_principal!(invitation_id) do
    case Repo.get(Invitation, invitation_id) do
      nil ->
        false

      invitation_ref ->
        DiscordSubjectLock.lock_principal!(invitation_ref.prospective_principal_id)
        true
    end
  end

  # Re-read the Continuation after the principal lock: another operation may
  # have committed a subject since the probe read.
  defp lock_subjects!(continuation_id, extra_subjects) do
    current_subject =
      case Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id) do
        %{provider_subject: subject} -> subject
        nil -> nil
      end

    [current_subject | extra_subjects]
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&DiscordSubjectLock.lock!/1)
  end

  defp lock_rows(continuation_id, now) do
    case lock_continuation(continuation_id) do
      nil ->
        {:error, :not_found}

      continuation ->
        attempt = lock_attempt(continuation.attempt_id)
        invitation = lock_invitation(continuation.invitation_id)
        build(continuation, attempt, invitation, now)
    end
  end

  defp build(continuation, attempt, invitation, now) do
    if related?(continuation, attempt, invitation) do
      {:ok,
       %__MODULE__{
         invitation: invitation,
         attempt: attempt,
         continuation: continuation,
         claims: lock_claims(continuation.id),
         now: now
       }}
    else
      {:error, :inconsistent}
    end
  end

  defp related?(_continuation, nil, _invitation), do: false
  defp related?(_continuation, _attempt, nil), do: false

  defp related?(continuation, attempt, invitation) do
    continuation.invitation_id == invitation.id and continuation.attempt_id == attempt.id and
      attempt.invitation_id == invitation.id
  end

  defp lock_continuation(continuation_id) do
    from(c in InvitationAcceptanceDiscordContinuation,
      where: c.id == ^continuation_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp lock_attempt(attempt_id) do
    from(a in InvitationAcceptanceAttempt, where: a.id == ^attempt_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp lock_invitation(invitation_id) do
    from(i in Invitation, where: i.id == ^invitation_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp lock_claims(continuation_id) do
    from(c in InvitationAcceptanceDiscordSubjectClaim,
      where: c.continuation_id == ^continuation_id,
      order_by: [asc: c.created_at],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp attempt_continuation_ref(attempt) do
    case Map.get(attempt.acceptance_data, "continuation_id") do
      continuation_id when is_binary(continuation_id) ->
        Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id)

      _ ->
        Repo.one(
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.attempt_id == ^attempt.id,
            order_by: [desc: c.created_at],
            limit: 1
          )
        )
    end
  end

  # ── Predicates over the locked graph ─────────────────────────────────

  @doc "The Claim that reserves the Continuation's own subject, if any."
  @spec claim(t()) :: map() | nil
  def claim(%__MODULE__{continuation: %{provider_subject: subject}, claims: claims})
      when is_binary(subject) do
    Enum.find(claims, &(&1.provider == "discord" and &1.provider_subject == subject))
  end

  def claim(%__MODULE__{}), do: nil

  @spec active_claim?(t()) :: boolean()
  def active_claim?(%__MODULE__{} = locked), do: not is_nil(claim(locked))

  @doc "The browser proof has been consumed into this Attempt."
  @spec consumed?(t()) :: boolean()
  def consumed?(%__MODULE__{attempt: attempt, continuation: continuation}) do
    Map.get(attempt.acceptance_data, "continuation_id") == continuation.id
  end

  @spec continuation_live?(t()) :: boolean()
  def continuation_live?(%__MODULE__{continuation: continuation}) do
    continuation.status in ["awaiting_oauth", "verified"]
  end

  @spec continuation_unexpired?(t()) :: boolean()
  def continuation_unexpired?(%__MODULE__{continuation: continuation, now: now}) do
    DateTime.compare(continuation.expires_at, now) == :gt
  end

  @spec invitation_unexpired?(t()) :: boolean()
  def invitation_unexpired?(%__MODULE__{invitation: invitation, now: now}) do
    DateTime.compare(invitation.expires_at, now) == :gt
  end

  @doc "A recoverable Attempt keeps its consumed Continuation past wall-clock expiry."
  @spec recoverable_consumed?(t()) :: boolean()
  def recoverable_consumed?(%__MODULE__{attempt: attempt} = locked) do
    consumed?(locked) and attempt.status in @recoverable_statuses
  end

  @spec recoverable_statuses() :: [String.t()]
  def recoverable_statuses, do: @recoverable_statuses

  @doc "An Attempt that has not yet bound Discord, Stripe, or payment input."
  @spec pre_oauth?(InvitationAcceptanceAttempt.t() | nil) :: boolean()
  def pre_oauth?(nil), do: false

  def pre_oauth?(attempt) do
    attempt.status == "processing" and attempt.acceptance_data == %{} and
      attempt.stripe_customer_id in [nil, ""] and attempt.stripe_state == %{}
  end

  @spec payment_ready?(InvitationAcceptanceAttempt.t()) :: boolean()
  def payment_ready?(attempt) do
    attempt.status == "processing" and
      present?(Map.get(attempt.acceptance_data, "continuation_id"))
  end

  @spec retry_allowed?(InvitationAcceptanceAttempt.t()) :: boolean()
  def retry_allowed?(attempt) do
    attempt.status in ["payment_pending", "provisioned"] and not is_nil(attempt.last_error) and
      not lease_active?(attempt)
  end

  @spec lease_active?(InvitationAcceptanceAttempt.t()) :: boolean()
  def lease_active?(%{operation_token: nil}), do: false
  def lease_active?(%{operation_started_at: nil}), do: false

  def lease_active?(attempt) do
    DateTime.compare(
      attempt.operation_started_at,
      DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:second)
    ) == :gt
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
