defmodule Dhc.Onboarding.Acceptance do
  @moduledoc """
  Owns one browser's Invitation Acceptance session behind an opaque handle.

  The handle is the only workflow identifier the browser holds (in a signed
  HttpOnly cookie). It never reveals whether the session currently lives in a
  Continuation, an Attempt, a Discord Subject Claim, or a payment lease, and no
  operation returns Ecto schemas or raw payment state: every browser-facing
  result is a closed safe view (`Dhc.Onboarding.Acceptance.View`) whose `state`
  field is the discriminator.

  Internally every authoritative read or write goes through one lock graph
  (`Dhc.Onboarding.Acceptance.Locked`), Stripe calls happen outside database
  transactions with a durable operation lease recorded first and re-validated
  afterwards, and synchronous payment submission, explicit retry, and Oban
  recovery all converge on the same private progression path.
  """

  import Ecto.Query
  require Logger

  alias Dhc.Auth.DiscordSubjectLock
  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.Principal
  alias Dhc.Discord.StagedAssignment
  alias Dhc.Invitations
  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Pricing
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.Acceptance.Locked
  alias Dhc.Onboarding.Acceptance.View
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordCollisionAuditEvent
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Onboarding.Workers.AcceptanceRecoveryWorker
  alias Dhc.Repo

  @opaque handle :: binary()
  @type view :: View.t()
  @type payment_input :: %{
          required(:next_of_kin_name) => String.t(),
          required(:next_of_kin_phone) => String.t(),
          optional(:confirmation_token) => String.t() | nil,
          optional(:coupon_code) => String.t() | nil,
          optional(:mandate_context) => map()
        }

  @continuation_ttl_seconds 15 * 60
  @live_continuation_statuses ["awaiting_oauth", "verified"]
  @active_attempt_statuses ["processing", "payment_pending", "cleanup_pending", "provisioned"]

  # ── Browser-facing operations ────────────────────────────────────────

  @doc """
  Verifies Invitation credentials and opens or resumes the acceptance session.

  A live session that this browser does not already hold (`existing_handle`)
  is refused with `:missing_browser_proof` so a second browser cannot hijack
  an in-flight acceptance.
  """
  @spec open(String.t(), String.t(), String.t() | Date.t(), handle() | nil) ::
          {:ok, handle(), view()}
          | {:error, :invalid_credentials | :invalid_invitation | :missing_browser_proof}
  def open(invitation_id, email, date_of_birth, existing_handle \\ nil) do
    with {:ok, invitation_id} <- cast_uuid(invitation_id),
         :ok <- Invitations.verify_credentials(invitation_id, email, date_of_birth) do
      Repo.transaction(fn -> open_locked(invitation_id, existing_handle, now()) end)
      |> case do
        {:ok, {handle, view}} -> {:ok, handle, view}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @doc """
  Reads the session's current safe view. Reading an expired, unconsumed
  session expires it durably, so a read and the expiry sweep reach the same
  terminal outcome.
  """
  @spec view(handle() | nil) :: {:ok, view()} | {:error, :restart_verification}
  def view(handle) do
    with_locked(handle, :restart_verification, &view_locked/1)
    |> case do
      {:ok, {:restart, _reason}} -> {:error, :restart_verification}
      {:ok, view} -> {:ok, view}
      {:error, _reason} -> {:error, :restart_verification}
    end
  end

  defp view_locked(%Locked{} = locked) do
    if expired_unconsumed?(locked) do
      expire!(locked)
      {:restart, :expired}
    else
      project_current!(locked)
    end
  end

  defp project_current!(%Locked{} = locked) do
    case View.current(locked) do
      {:ok, view} -> view
      :restart -> Repo.rollback(:restart_verification)
    end
  end

  @doc """
  Binds the Discord subject from verified OAuth claims to the session by
  reserving a transient Subject Claim. A subject already owned elsewhere ends
  the session as a neutral `:collision`; `join_grant` (the OAuth token) is
  stored only on success.
  """
  @spec verify_discord(handle(), map(), map() | nil) ::
          {:ok, view()} | {:error, :collision | :invalid_continuation | atom()}
  def verify_discord(handle, claims, join_grant \\ nil) when is_map(claims) do
    with {:ok, continuation_id} <- cast_uuid(handle),
         subject when is_binary(subject) and subject != "" <- Map.get(claims, "sub") do
      Repo.transaction(fn ->
        locked = lock!(continuation_id, :invalid_continuation, subjects: [subject])
        result = verify_discord_locked(locked, subject, claims)
        maybe_create_join_grant!(result, continuation_id, join_grant)
        result
      end)
      |> unwrap_nested()
    else
      _ -> {:error, :invalid_continuation}
    end
  end

  @doc "Records a Discord OAuth failure or provider-side cancellation before any subject was bound."
  @spec fail_discord(handle(), :cancelled | :failed) ::
          {:ok, view()} | {:error, :invalid_continuation}
  def fail_discord(handle, outcome) when outcome in [:cancelled, :failed] do
    with_locked(handle, :invalid_continuation, fn locked ->
      ensure!(
        locked.continuation.status == "awaiting_oauth" and Locked.pre_oauth?(locked.attempt),
        :invalid_continuation
      )

      continuation = terminalize_continuation!(locked, Atom.to_string(outcome), nil)
      attempt = decline_attempt!(locked.attempt, "discord_#{outcome}", locked.now)
      project_after_terminal(locked, continuation, attempt)
    end)
  end

  @doc "Abandons a live session before payment; the browser must verify credentials again."
  @spec cancel_discord(handle()) :: {:ok, view()} | {:error, :invalid_continuation}
  def cancel_discord(handle) do
    with_locked(handle, :invalid_continuation, fn locked ->
      ensure!(
        Locked.continuation_live?(locked) and Locked.pre_oauth?(locked.attempt),
        :invalid_continuation
      )

      terminalize_continuation!(locked, "cancelled", locked.continuation.provider_subject)
      decline_attempt!(locked.attempt, "discord_cancelled", locked.now)
      View.restart()
    end)
  end

  @doc "The dashboard path the OAuth callback returns the browser to."
  @spec resume_path(handle()) :: {:ok, String.t()} | {:error, :invalid_continuation}
  def resume_path(handle) do
    with {:ok, continuation_id} <- cast_uuid(handle),
         %InvitationAcceptanceDiscordContinuation{invitation_id: invitation_id} <-
           Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id) do
      {:ok, "/members/signup/#{invitation_id}/resume"}
    else
      _ -> {:error, :invalid_continuation}
    end
  end

  @doc """
  Consumes the verified Discord proof into the Attempt exactly once, which is
  what admits the browser to the payment step. Repeated calls return the
  current projection without side effects.
  """
  @spec consume_proof(handle()) :: {:ok, view()} | {:error, :invalid_continuation}
  def consume_proof(handle) do
    with_locked(handle, :invalid_continuation, fn locked ->
      cond do
        proof_consumed?(locked) ->
          View.attempt(locked.attempt, locked.invitation)

        not consumable?(locked) ->
          Repo.rollback(:invalid_continuation)

        true ->
          attempt =
            locked.attempt
            |> Ecto.Changeset.change(
              acceptance_data:
                Map.put(locked.attempt.acceptance_data, "continuation_id", locked.continuation.id)
            )
            |> Repo.update!()

          View.attempt(attempt, locked.invitation)
      end
    end)
  end

  @doc """
  Read-only pricing preview. The Invitation's pricing tier decides the
  discount; a user-supplied coupon only applies to standard invitations.
  """
  @spec preview_pricing(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def preview_pricing(invitation_id, coupon_candidate \\ nil) do
    with {:ok, invitation_id} <- cast_uuid(invitation_id),
         %Invitation{} = invitation <- pending_unexpired_invitation(invitation_id) do
      preview_tier_pricing(invitation, coupon_candidate)
    else
      _ -> {:error, :not_found}
    end
  end

  defp preview_tier_pricing(%Invitation{pricing_tier: "coach"}, _coupon),
    do: {:ok, Pricing.complimentary_preview()}

  defp preview_tier_pricing(invitation, coupon_candidate) do
    with {:ok, discount} <- effective_discount(invitation, coupon_candidate) do
      stripe_adapter().preview_membership(discount)
    end
  end

  @doc """
  Records the browser's payment submission durably, then progresses Stripe.

  The first valid submission canonicalises next-of-kin details, the Stripe
  ConfirmationToken, coupon and mandate context into the Attempt; every later
  submission for the same session reuses that durable input and makes no new
  provider call.
  """
  @spec submit_payment(handle(), payment_input()) :: {:ok, view()} | {:error, term()}
  def submit_payment(handle, input) when is_map(input) do
    with :ok <- validate_next_of_kin(input),
         {:ok, continuation_id} <- cast_or(handle, :invalid_continuation),
         {:ok, recorded} <- record_submission(continuation_id, input) do
      case recorded do
        {:advance, attempt_id} -> progress(attempt_id, :automatic)
        {:current, view} -> {:ok, view}
      end
    end
  end

  @doc "Explicitly resumes a stalled payment or finalization for the browser."
  @spec retry(handle()) :: {:ok, view()} | {:error, term()}
  def retry(handle) do
    with {:ok, continuation_id} <- cast_or(handle, :invalid_continuation),
         {:ok, attempt_id} <- consumed_attempt_id(continuation_id) do
      progress(attempt_id, :explicit)
    end
  end

  # ── Background operations ────────────────────────────────────────────

  @doc """
  Recovers an Attempt from `payment_pending`, `cleanup_pending`, or
  `provisioned` through the same progression path as a browser submission.
  """
  @spec recover(Ecto.UUID.t()) :: {:ok, view()} | :discard | {:error, term()}
  def recover(attempt_id) do
    case cast_uuid(attempt_id) do
      {:ok, attempt_id} -> progress(attempt_id, :automatic)
      :error -> :discard
    end
  end

  @doc "Schedules recovery for every recoverable Attempt owned by the event's Stripe customer."
  @spec reconcile_stripe_event(map()) :: :ok
  def reconcile_stripe_event(stripe_object) when is_map(stripe_object) do
    customer_id =
      case Map.get(stripe_object, "customer") do
        id when is_binary(id) -> id
        %{"id" => id} when is_binary(id) -> id
        _ -> nil
      end

    if customer_id not in [nil, ""] do
      recoverable = Locked.recoverable_statuses()

      from(a in InvitationAcceptanceAttempt,
        where: a.stripe_customer_id == ^customer_id and a.status in ^recoverable,
        select: a.id
      )
      |> Repo.all()
      |> Enum.each(&enqueue_recovery/1)
    end

    :ok
  end

  @doc """
  Expires every live Continuation past its deadline (unless its proof has been
  consumed into a recoverable Attempt) and reports Claims whose owning
  Continuation no longer agrees with them.
  """
  @spec expire_continuations() ::
          {:ok, non_neg_integer()} | {:error, {:inconsistent_claims, [Ecto.UUID.t()]}}
  def expire_continuations do
    now = now()

    expired_ids =
      from(c in InvitationAcceptanceDiscordContinuation,
        where: c.status in @live_continuation_statuses and c.expires_at <= ^now,
        select: c.id
      )
      |> Repo.all()

    inconsistent_ids =
      expired_ids
      |> Enum.flat_map(&expire_continuation(&1, now))
      |> Kernel.++(inconsistent_claim_continuation_ids())
      |> Enum.uniq()
      |> Enum.sort()

    case inconsistent_ids do
      [] -> {:ok, length(expired_ids)}
      ids -> {:error, {:inconsistent_claims, ids}}
    end
  end

  # ── open ─────────────────────────────────────────────────────────────

  defp open_locked(invitation_id, existing_handle, now) do
    ensure!(Locked.lock_invitation_principal!(invitation_id), :invalid_invitation)

    invitation = lock_pending_invitation!(invitation_id)
    ensure_invitation_eligible!(invitation)
    ensure!(DateTime.compare(invitation.expires_at, now) == :gt, :invalid_invitation)

    attempt = lock_active_attempt(invitation.id)
    ensure!(is_nil(attempt) or Locked.pre_oauth?(attempt), :invalid_invitation)
    attempt = attempt || insert_pre_oauth_attempt!(invitation)

    continuation =
      attempt.id
      |> lock_live_continuation()
      |> resume_or_replace_continuation(invitation, attempt, existing_handle, now)

    {continuation.id, View.continuation(continuation, invitation)}
  end

  defp lock_pending_invitation!(invitation_id) do
    from(i in Invitation,
      where: i.id == ^invitation_id and i.status == "pending",
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:invalid_invitation)
      invitation -> invitation
    end
  end

  defp ensure_invitation_eligible!(invitation) do
    email = String.downcase(invitation.email)

    principal_exists? =
      Repo.exists?(from(p in Principal, where: fragment("lower(?)", p.email) == ^email))

    member_exists? =
      Repo.exists?(from(m in MemberProfile, where: m.id == ^invitation.prospective_principal_id))

    ensure!(not (principal_exists? or member_exists?), :invalid_invitation)
  end

  defp lock_active_attempt(invitation_id) do
    from(a in InvitationAcceptanceAttempt,
      where: a.invitation_id == ^invitation_id and a.status in @active_attempt_statuses,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp insert_pre_oauth_attempt!(invitation) do
    prior_customer_id =
      from(a in InvitationAcceptanceAttempt,
        where: a.invitation_id == ^invitation.id and not is_nil(a.stripe_customer_id),
        order_by: [desc: a.created_at],
        limit: 1,
        select: a.stripe_customer_id
      )
      |> Repo.one()

    %InvitationAcceptanceAttempt{
      invitation_id: invitation.id,
      acceptance_data: %{},
      stripe_customer_id: prior_customer_id
    }
    |> Repo.insert!()
  end

  defp lock_live_continuation(attempt_id) do
    from(c in InvitationAcceptanceDiscordContinuation,
      where: c.attempt_id == ^attempt_id and c.status in @live_continuation_statuses,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp resume_or_replace_continuation(nil, invitation, attempt, _handle, now),
    do: insert_continuation!(invitation, attempt, now)

  defp resume_or_replace_continuation(continuation, invitation, attempt, existing_handle, now) do
    cond do
      DateTime.compare(continuation.expires_at, now) != :gt ->
        terminalize_continuation!(continuation, "expired", continuation.provider_subject, now)
        insert_continuation!(invitation, attempt, now)

      browser_owns?(continuation, existing_handle) ->
        continuation

      true ->
        Repo.rollback(:missing_browser_proof)
    end
  end

  defp browser_owns?(continuation, existing_handle) do
    case cast_uuid(existing_handle) do
      {:ok, continuation_id} -> continuation.id == continuation_id
      :error -> false
    end
  end

  defp insert_continuation!(invitation, attempt, now) do
    session_expiry = DateTime.add(now, @continuation_ttl_seconds, :second)

    %InvitationAcceptanceDiscordContinuation{
      invitation_id: invitation.id,
      attempt_id: attempt.id,
      expires_at: Enum.min([invitation.expires_at, session_expiry], DateTime)
    }
    |> Repo.insert!()
  end

  # ── view / expiry on read ────────────────────────────────────────────

  defp expired_unconsumed?(%Locked{} = locked) do
    Locked.continuation_live?(locked) and not Locked.continuation_unexpired?(locked) and
      not Locked.consumed?(locked)
  end

  defp expire!(%Locked{} = locked) do
    terminalize_continuation!(locked, "expired", locked.continuation.provider_subject)

    if Locked.pre_oauth?(locked.attempt),
      do: decline_attempt!(locked.attempt, "discord_expired", locked.now)

    :ok
  end

  # ── verify_discord ───────────────────────────────────────────────────

  defp verify_discord_locked(%Locked{} = locked, subject, claims) do
    ensure!(
      locked.invitation.status == "pending" and locked.attempt.status == "processing",
      :invalid_continuation
    )

    case locked.continuation do
      %{status: "verified", provider_subject: ^subject} = continuation ->
        {:ok, View.continuation(continuation, locked.invitation)}

      %{status: "awaiting_oauth"} ->
        if Locked.continuation_unexpired?(locked),
          do: claim_subject(locked, subject, claims),
          else: {:error, :invalid_continuation}

      _other ->
        {:error, :invalid_continuation}
    end
  end

  defp claim_subject(locked, subject, claims) do
    case subject_owner(subject) do
      {:external_identity, principal_id} ->
        collide!(locked, subject, "external_identity", principal_id)

      {:staged_assignment, principal_id} ->
        collide!(locked, subject, "staged_assignment", principal_id)

      :unowned ->
        if insert_claim(locked.continuation, subject, locked.now) == 1,
          do: mark_verified(locked, subject, claims),
          else: collide!(locked, subject, "active_claim", nil)
    end
  end

  # Row-locks whichever permanent or staged binding already owns the subject so
  # the collision decision cannot race its promotion or retirement.
  defp subject_owner(subject) do
    cond do
      identity = active_external_identity(subject) ->
        {:external_identity, identity.principal_id}

      assignment = active_staged_assignment(subject) ->
        {:staged_assignment, assignment.principal_id}

      true ->
        :unowned
    end
  end

  defp active_external_identity(subject) do
    from(e in ExternalIdentity,
      where: e.provider == "discord" and e.provider_subject == ^subject and is_nil(e.retired_at),
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp active_staged_assignment(subject) do
    from(a in StagedAssignment,
      where:
        a.provider == "discord" and a.provider_subject == ^subject and
          a.state in ["proposed", "approved"],
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp insert_claim(continuation, subject, now) do
    {inserted, _rows} =
      Repo.insert_all(
        InvitationAcceptanceDiscordSubjectClaim,
        [
          %{
            id: Ecto.UUID.generate(),
            continuation_id: continuation.id,
            provider: "discord",
            provider_subject: subject,
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:provider, :provider_subject]
      )

    inserted
  end

  defp mark_verified(locked, subject, claims) do
    continuation =
      locked.continuation
      |> Ecto.Changeset.change(
        status: "verified",
        provider_subject: subject,
        subject_fingerprint: subject_fingerprint(subject),
        display_metadata: display_metadata(claims)
      )
      |> Repo.update!()

    {:ok, View.continuation(continuation, locked.invitation)}
  end

  defp collide!(locked, subject, reason_code, existing_principal_id) do
    terminalize_continuation!(locked, "collision", subject)

    %InvitationAcceptanceDiscordCollisionAuditEvent{
      continuation_id: locked.continuation.id,
      existing_principal_id: existing_principal_id,
      subject_fingerprint: subject_fingerprint(subject),
      reason_code: reason_code,
      created_at: locked.now
    }
    |> Repo.insert!()

    locked.attempt
    |> Ecto.Changeset.change(
      status: "declined",
      concluded_at: locked.now,
      last_error: "discord_collision"
    )
    |> Repo.update!()

    {:error, :collision}
  end

  defp maybe_create_join_grant!({:ok, _view}, continuation_id, join_grant)
       when is_map(join_grant) do
    case Dhc.Discord.create_join_grant(continuation_id, join_grant) do
      {:ok, _grant} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_create_join_grant!(_result, _continuation_id, _join_grant), do: :ok

  defp display_metadata(claims) do
    %{}
    |> maybe_put("username", Map.get(claims, "preferred_username"))
    |> maybe_put("avatarUrl", Map.get(claims, "picture"))
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp project_after_terminal(%Locked{} = locked, continuation, attempt) do
    case View.current(%Locked{locked | continuation: continuation, attempt: attempt}) do
      {:ok, view} -> view
      :restart -> View.restart()
    end
  end

  # ── consume_proof ────────────────────────────────────────────────────

  defp proof_consumed?(%Locked{attempt: attempt} = locked) do
    Locked.consumed?(locked) and
      attempt.status in ["processing", "payment_pending", "provisioned", "completed"]
  end

  defp consumable?(%Locked{} = locked) do
    locked.invitation.status == "pending" and locked.attempt.status == "processing" and
      locked.continuation.status == "verified" and Locked.continuation_unexpired?(locked) and
      Locked.active_claim?(locked)
  end

  # ── submit_payment ───────────────────────────────────────────────────

  defp validate_next_of_kin(input) do
    if present?(Map.get(input, :next_of_kin_name)) and
         present?(Map.get(input, :next_of_kin_phone)),
       do: :ok,
       else: {:error, :invalid_acceptance_details}
  end

  defp record_submission(continuation_id, input) do
    Repo.transaction(fn ->
      locked = lock!(continuation_id, :invalid_continuation)
      ensure_confirmation_token!(locked.invitation, input)

      cond do
        payment_recorded?(locked) ->
          {:current, View.attempt(locked.attempt, locked.invitation)}

        not payment_recordable?(locked) ->
          Repo.rollback(:invalid_continuation)

        true ->
          {:advance, record_payment_input!(locked, input).id}
      end
    end)
  end

  defp ensure_confirmation_token!(%Invitation{pricing_tier: "coach"}, _input), do: :ok

  defp ensure_confirmation_token!(_invitation, input),
    do: ensure!(present?(Map.get(input, :confirmation_token)), :invalid_acceptance_details)

  defp payment_recorded?(%Locked{attempt: attempt} = locked) do
    Locked.consumed?(locked) and attempt.status in ["payment_pending", "provisioned", "completed"]
  end

  defp payment_recordable?(%Locked{} = locked) do
    locked.invitation.status == "pending" and Locked.payment_ready?(locked.attempt) and
      locked.continuation.status == "verified" and Locked.active_claim?(locked)
  end

  defp record_payment_input!(%Locked{attempt: attempt, continuation: continuation}, input) do
    mandate_context = Map.get(input, :mandate_context, %{})

    acceptance_data = %{
      "continuation_id" => continuation.id,
      "next_of_kin_name" => String.trim(input.next_of_kin_name),
      "next_of_kin_phone" => String.trim(input.next_of_kin_phone),
      "payment" => %{
        "confirmation_token" => Map.get(input, :confirmation_token),
        "coupon_code" => blank_to_nil(Map.get(input, :coupon_code)),
        "mandate_context" => %{
          "ip_address" => Map.get(mandate_context, :ip_address),
          "user_agent" => Map.get(mandate_context, :user_agent)
        }
      }
    }

    attempt =
      attempt
      |> Ecto.Changeset.change(
        status: "payment_pending",
        acceptance_data: acceptance_data,
        stripe_state: Map.put(attempt.stripe_state, "payment_operation_started", true)
      )
      |> Repo.update!()

    enqueue_recovery(attempt.id)
    attempt
  end

  defp consumed_attempt_id(continuation_id) do
    with_locked(continuation_id, :invalid_continuation, fn locked ->
      ensure!(Locked.consumed?(locked), :invalid_continuation)
      locked.attempt.id
    end)
  end

  # ── Progression: the one path for submission, retry, and recovery ────

  defp progress(attempt_id, mode) do
    case acquire_lease(attempt_id, mode) do
      {:ok, %Locked{attempt: %{status: "payment_pending"}} = locked} -> begin_payment(locked)
      {:ok, %Locked{attempt: %{status: "provisioned"}} = locked} -> finalize(locked)
      {:ok, %Locked{attempt: %{status: "cleanup_pending"}} = locked} -> cleanup(locked)
      {:ok, %Locked{attempt: %{status: "processing"}}} -> {:error, :payment_not_started}
      {:ok, %Locked{} = locked} -> {:ok, View.attempt(locked.attempt, locked.invitation)}
      {:error, :not_found} -> :discard
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_lease(attempt_id, mode) do
    Repo.transaction(fn ->
      %Locked{} = locked = lock_attempt!(attempt_id, now())

      if mode == :explicit and not Locked.retry_allowed?(locked.attempt),
        do: Repo.rollback(:retry_not_allowed)

      if Locked.lease_active?(locked.attempt), do: Repo.rollback(:operation_in_progress)

      if locked.attempt.status in Locked.recoverable_statuses() do
        ensure_recoverable_claim!(locked)
        %Locked{locked | attempt: lease!(locked.attempt)}
      else
        locked
      end
    end)
  end

  defp ensure_recoverable_claim!(%Locked{continuation: continuation} = locked) do
    ensure!(
      continuation.status == "verified" and is_binary(continuation.provider_subject),
      :inconsistent_discord_continuation
    )

    ensure!(Locked.active_claim?(locked), :inconsistent_discord_claim)
  end

  defp lease!(attempt) do
    attempt
    |> Ecto.Changeset.change(
      operation_token: Ecto.UUID.generate(),
      operation_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  defp begin_payment(%Locked{invitation: invitation, attempt: attempt}) do
    attrs = payment_attrs(attempt)

    with {:ok, _locked} <- fence(attempt),
         {:ok, discount} <- effective_discount(invitation, attrs.coupon_code),
         {:ok, attempt, payment_plan} <- ensure_payment_plan(attempt, discount),
         {:ok, attempt} <- ensure_customer(invitation, attempt),
         {:ok, _locked} <- fence(attempt) do
      provision(invitation, attempt, payment_plan, discount, attrs)
    else
      # A misconfigured tier coupon is an operator error, not a payment
      # failure: surface it without recording a provider failure or scheduling
      # retries, and release the lease so the invitee can retry once fixed.
      {:error, :tier_coupon_not_configured} = error ->
        Logger.warning("[onboarding] Pricing tier coupon is not configured",
          invitation_id: invitation.id,
          pricing_tier: invitation.pricing_tier
        )

        release_lease(attempt, "tier_coupon_not_configured")
        error

      {:error, reason} ->
        provider_failure(attempt, reason)
    end
  end

  defp provision(invitation, attempt, %{requirement: requirement} = payment_plan, discount, attrs) do
    base_attrs =
      case requirement do
        :paid -> attrs
        :complimentary -> %{complimentary: true, coupon_code: discount}
      end

    provider_attrs =
      Map.merge(base_attrs, %{
        payment_plan: payment_plan,
        attempt_id: attempt.id,
        invitation_id: invitation.id,
        customer_id: attempt.stripe_customer_id,
        stripe_state: attempt.stripe_state,
        fence: fn -> fence_ok(attempt) end,
        progress: &record_stripe_progress(attempt, &1)
      })

    with {:ok, _locked} <- fence(attempt) do
      stripe_adapter().provision_membership(provider_attrs)
    end
    |> case do
      {:ok, stripe_state} ->
        provisioned(invitation, attempt, stripe_state)

      {:pending, %{"payment_intent_status" => "processing"} = stripe_state} ->
        provisioned(invitation, attempt, stripe_state)

      {:pending, stripe_state} ->
        with :ok <- record_stripe_progress(attempt, stripe_state),
             {:ok, current} <- fence(attempt) do
          {:ok, View.attempt(current.attempt, invitation)}
        end

      {:error, reason} ->
        provider_failure(attempt, reason)
    end
  end

  defp provisioned(invitation, attempt, stripe_state) do
    with {:ok, %Locked{} = locked} <- mark_provisioned(attempt, stripe_state) do
      finalize(%Locked{locked | invitation: invitation})
    end
  end

  defp mark_provisioned(attempt, stripe_state) do
    Repo.transaction(fn ->
      %Locked{attempt: current} = locked = owned_fence!(attempt)

      updated =
        case current.status do
          "payment_pending" ->
            current
            |> Ecto.Changeset.change(
              status: "provisioned",
              stripe_state: Map.merge(current.stripe_state, stripe_state),
              last_error: nil
            )
            |> Repo.update!()

          "provisioned" ->
            current
            |> Ecto.Changeset.change(stripe_state: Map.merge(current.stripe_state, stripe_state))
            |> Repo.update!()

          _status ->
            Repo.rollback(:attempt_not_processing)
        end

      enqueue_recovery(updated.id)
      %Locked{locked | attempt: updated}
    end)
  end

  defp finalize(%Locked{invitation: invitation, attempt: attempt, continuation: continuation}) do
    data = attempt.acceptance_data

    case finalizer().convert_with_discord(
           invitation.id,
           attempt.id,
           continuation.id,
           Map.fetch!(data, "next_of_kin_name"),
           Map.fetch!(data, "next_of_kin_phone"),
           attempt.stripe_customer_id,
           attempt.operation_token
         ) do
      {:ok, _member} ->
        {:ok, View.accepted(invitation)}

      {:error, reason} ->
        if accepted_concurrently?(attempt.id) do
          {:ok, View.accepted(invitation)}
        else
          release_lease(attempt, "local_finalization_failed")
          {:error, reason}
        end
    end
  end

  # Finalization may lose a race against a concurrent recovery that already
  # converted the same Attempt; re-read through the canonical lock graph.
  defp accepted_concurrently?(attempt_id) do
    Repo.transaction(fn ->
      case Locked.by_attempt(attempt_id, now()) do
        {:ok, %Locked{invitation: invitation, attempt: attempt}} ->
          invitation.status == "accepted" and attempt.status == "completed"

        {:error, _reason} ->
          false
      end
    end)
    |> case do
      {:ok, accepted?} -> accepted?
      {:error, _reason} -> false
    end
  end

  defp cleanup(%Locked{attempt: attempt} = locked) do
    cleanup_state =
      attempt.stripe_state
      |> Map.put("acceptance_attempt_id", attempt.id)
      |> Map.put("customer_id", attempt.stripe_customer_id)

    case stripe_adapter().cancel_membership(cleanup_state) do
      :ok ->
        with {:ok, _declined} <- decline_cleaned(locked), do: {:ok, View.restart()}

      {:error, reason} ->
        release_lease(attempt, "stripe_cleanup_unavailable")
        {:error, reason}
    end
  end

  # A cleanup whose lease was superseded while Stripe was called must not
  # conclude the Attempt: the current owner decides.
  defp decline_cleaned(%Locked{attempt: attempt}) do
    Repo.transaction(fn ->
      case owned_attempt(attempt) do
        {:ok, locked} ->
          terminalize_continuation!(locked, "failed", locked.continuation.provider_subject)
          decline_attempt!(locked.attempt, locked.attempt.last_error, locked.now)

        {:error, _reason} ->
          Repo.rollback(:stale_acceptance_operation)
      end
    end)
  end

  defp provider_failure(attempt, reason) do
    Logger.warning("Stripe progression failed for Invitation Acceptance",
      attempt_id: attempt.id,
      stripe_error: stripe_error_summary(reason)
    )

    if stripe_adapter().retryable_failure?(reason) do
      release_lease(attempt, controlled_error(reason))
      {:error, {:provider_unavailable, reason}}
    else
      conclude_failed(attempt, reason)
      {:error, {:payment_failed, reason}}
    end
  end

  # A terminal provider failure moves the Attempt to cleanup_pending, releases
  # the lease, then runs cleanup through the shared progression so the
  # synchronous path and later recovery share one code path.
  defp conclude_failed(attempt, reason) do
    Repo.transaction(fn ->
      case owned_attempt(attempt) do
        {:ok, locked} ->
          current =
            locked.attempt
            |> Ecto.Changeset.change(
              status: "cleanup_pending",
              last_error: controlled_error(reason),
              operation_token: nil,
              operation_started_at: nil
            )
            |> Repo.update!()

          enqueue_recovery(current.id)
          current.id

        {:error, _reason} ->
          Repo.rollback(:stale_acceptance_operation)
      end
    end)
    |> case do
      {:ok, attempt_id} -> progress(attempt_id, :automatic)
      {:error, :stale_acceptance_operation} -> :ok
    end
  end

  defp release_lease(attempt, error_code) do
    Repo.transaction(fn ->
      case owned_attempt(attempt) do
        {:ok, %Locked{attempt: current}} when current.status in @active_attempt_statuses ->
          current
          |> Ecto.Changeset.change(
            last_error: error_code,
            operation_token: nil,
            operation_started_at: nil
          )
          |> Repo.update!()

        _stale_or_terminal ->
          :ok
      end
    end)

    :ok
  end

  # ── Stripe helpers ───────────────────────────────────────────────────

  # The Invitation's pricing tier decides the discount; a tier invitee never
  # supplies (or needs) a coupon code, so tiers can never stack with one.
  defp effective_discount(%Invitation{pricing_tier: "coach"}, _coupon),
    do: Pricing.tier_coupon_id(:coach)

  defp effective_discount(%Invitation{pricing_tier: "student"}, _coupon),
    do: Pricing.tier_coupon_id(:student)

  defp effective_discount(_invitation, coupon), do: {:ok, coupon}

  defp ensure_payment_plan(attempt, discount) do
    case Map.get(attempt.stripe_state, "payment_plan") do
      plan when is_map(plan) ->
        {:ok, attempt, deserialize_payment_plan(plan)}

      _missing ->
        with {:ok, plan} <- stripe_adapter().prepare_payment(discount),
             {:ok, attempt} <- persist_payment_plan(attempt, plan) do
          {:ok, attempt, plan}
        end
    end
  end

  defp persist_payment_plan(attempt, plan) do
    Repo.transaction(fn ->
      %Locked{attempt: current} = owned_fence!(attempt)

      current
      |> Ecto.Changeset.change(
        stripe_state: Map.put(current.stripe_state, "payment_plan", serialize_payment_plan(plan))
      )
      |> Repo.update!()
    end)
  end

  defp serialize_payment_plan(plan) do
    %{
      "requirement" => Atom.to_string(plan.requirement),
      "monthly_price_id" => plan.monthly_price_id,
      "annual_price_id" => plan.annual_price_id,
      "coupon_id" => plan.coupon_id,
      "promotion_code_id" => plan.promotion_code_id,
      "migration" => plan.migration?,
      "discount_targets" =>
        plan |> Map.get(:discount_targets, [:monthly, :annual]) |> Enum.map(&Atom.to_string/1)
    }
  end

  defp deserialize_payment_plan(plan) do
    %{
      requirement:
        if(Map.get(plan, "requirement") == "complimentary", do: :complimentary, else: :paid),
      monthly_price_id: Map.fetch!(plan, "monthly_price_id"),
      annual_price_id: Map.fetch!(plan, "annual_price_id"),
      coupon_id: Map.get(plan, "coupon_id"),
      promotion_code_id: Map.get(plan, "promotion_code_id"),
      migration?: Map.get(plan, "migration", false),
      discount_targets:
        plan
        |> Map.get("discount_targets", ["monthly", "annual"])
        |> Enum.map(&cast_discount_target/1)
    }
  end

  defp cast_discount_target("annual"), do: :annual
  defp cast_discount_target(_kind), do: :monthly

  defp ensure_customer(
         _invitation,
         %InvitationAcceptanceAttempt{stripe_customer_id: id} = attempt
       )
       when is_binary(id) and id != "",
       do: {:ok, attempt}

  defp ensure_customer(invitation, attempt) do
    attrs = %{
      email: invitation.email,
      name:
        [invitation.first_name, invitation.last_name]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" "),
      invited_by_id: invitation.created_by_principal_id || invitation.prospective_principal_id,
      attempt_id: attempt.id,
      idempotency_key: "invitation-acceptance-attempt:#{attempt.id}:customer"
    }

    with {:ok, _locked} <- fence(attempt),
         {:ok, customer_id} <- stripe_adapter().create_customer(attrs),
         {:ok, %Locked{attempt: current}} <- fence(attempt) do
      if current.stripe_customer_id in [nil, ""],
        do: current |> Ecto.Changeset.change(stripe_customer_id: customer_id) |> Repo.update(),
        else: {:ok, current}
    end
  end

  defp payment_attrs(%InvitationAcceptanceAttempt{acceptance_data: acceptance_data}) do
    payment = Map.get(acceptance_data, "payment", %{})
    mandate_context = Map.get(payment, "mandate_context", %{})

    %{
      confirmation_token: Map.get(payment, "confirmation_token"),
      coupon_code: Map.get(payment, "coupon_code"),
      mandate_context: %{
        ip_address: Map.get(mandate_context, "ip_address"),
        user_agent: Map.get(mandate_context, "user_agent")
      }
    }
  end

  defp record_stripe_progress(attempt, progress) when is_map(progress) do
    Repo.transaction(fn ->
      %Locked{attempt: current} = owned_fence!(attempt)

      current
      |> Ecto.Changeset.change(stripe_state: Map.merge(current.stripe_state, progress))
      |> Repo.update!()
    end)
    |> case do
      {:ok, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Fences: revalidate ownership and relationships between provider calls ──

  # The payment fence: the whole graph is consistent, the Continuation is still
  # verified with its Claim, the Invitation is pending, the Attempt is mid
  # payment, and this operation still holds the lease.
  defp fence(attempt) do
    Repo.transaction(fn -> owned_fence!(attempt) end)
  end

  defp fence_ok(attempt) do
    case fence(attempt) do
      {:ok, _locked} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp owned_fence!(attempt) do
    locked = lock_attempt!(attempt.id, now())

    ensure!(
      locked.continuation.status == "verified" and locked.invitation.status == "pending" and
        locked.attempt.status in ["payment_pending", "provisioned"] and
        Locked.active_claim?(locked),
      :payment_fence_invalid
    )

    ensure!(
      locked.attempt.operation_token == attempt.operation_token,
      :stale_acceptance_operation
    )

    locked
  end

  # Ownership only: the Attempt still carries this operation's lease.
  defp owned_attempt(attempt) do
    case Locked.by_attempt(attempt.id, now()) do
      {:ok, %Locked{attempt: current} = locked}
      when current.operation_token == attempt.operation_token ->
        {:ok, locked}

      {:ok, _locked} ->
        {:error, :stale_acceptance_operation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_attempt!(attempt_id, now) do
    case Locked.by_attempt(attempt_id, now) do
      {:ok, locked} -> locked
      {:error, :not_found} -> Repo.rollback(:not_found)
      {:error, :legacy_attempt} -> Repo.rollback(:legacy_attempt)
      {:error, :inconsistent} -> Repo.rollback(:payment_fence_invalid)
    end
  end

  # ── Expiry sweep ─────────────────────────────────────────────────────

  defp expire_continuation(continuation_id, now) do
    Repo.transaction(fn ->
      case Locked.by_continuation(continuation_id, now) do
        {:ok, locked} -> expire_locked(locked)
        {:error, :not_found} -> :ok
        {:error, :inconsistent} -> :inconsistent
      end
    end)
    |> case do
      {:ok, :ok} -> []
      _inconsistent_or_failed -> [continuation_id]
    end
  end

  defp expire_locked(%Locked{} = locked) do
    cond do
      not Locked.continuation_live?(locked) or Locked.continuation_unexpired?(locked) ->
        :ok

      Locked.recoverable_consumed?(locked) ->
        :ok

      locked.attempt.status != "processing" or not expiry_claim_fence?(locked) ->
        :inconsistent

      true ->
        terminalize_continuation!(locked, "expired", locked.continuation.provider_subject)
        decline_attempt!(locked.attempt, "discord_expired", locked.now)
        :ok
    end
  end

  defp expiry_claim_fence?(%Locked{continuation: %{status: "awaiting_oauth"}, claims: claims}),
    do: claims == []

  defp expiry_claim_fence?(%Locked{continuation: %{status: "verified"}, claims: [_one]} = locked),
    do: Locked.active_claim?(locked)

  defp expiry_claim_fence?(%Locked{}), do: false

  defp inconsistent_claim_continuation_ids do
    mismatched =
      from(claim in InvitationAcceptanceDiscordSubjectClaim,
        join: continuation in InvitationAcceptanceDiscordContinuation,
        on: continuation.id == claim.continuation_id,
        where:
          continuation.status != "verified" or claim.provider != "discord" or
            claim.provider_subject != continuation.provider_subject,
        select: continuation.id
      )
      |> Repo.all()

    verified_without_claim =
      from(continuation in InvitationAcceptanceDiscordContinuation,
        left_join: claim in InvitationAcceptanceDiscordSubjectClaim,
        on:
          claim.continuation_id == continuation.id and claim.provider == "discord" and
            claim.provider_subject == continuation.provider_subject,
        where: continuation.status == "verified" and is_nil(claim.id),
        select: continuation.id
      )
      |> Repo.all()

    mismatched ++ verified_without_claim
  end

  # ── Terminal transitions ─────────────────────────────────────────────

  defp terminalize_continuation!(%Locked{continuation: continuation, now: now}, status, subject),
    do: terminalize_continuation!(continuation, status, subject, now)

  defp terminalize_continuation!(continuation, status, subject, now) do
    maybe_lock_subject!(subject)

    Repo.delete_all(
      from(c in InvitationAcceptanceDiscordSubjectClaim,
        where: c.continuation_id == ^continuation.id
      )
    )

    continuation
    |> Ecto.Changeset.change(
      status: status,
      concluded_at: now,
      provider_subject: nil,
      display_metadata: %{},
      subject_fingerprint: terminal_subject_fingerprint(status, subject)
    )
    |> Repo.update!()
  end

  defp terminal_subject_fingerprint("failed", _subject), do: nil

  defp terminal_subject_fingerprint(_status, subject) when is_binary(subject) and subject != "",
    do: subject_fingerprint(subject)

  defp terminal_subject_fingerprint(_status, _subject), do: nil

  defp maybe_lock_subject!(subject) when is_binary(subject) and subject != "",
    do: DiscordSubjectLock.lock!(subject)

  defp maybe_lock_subject!(_subject), do: :ok

  defp decline_attempt!(attempt, reason, now) do
    attempt
    |> Ecto.Changeset.change(
      status: "declined",
      concluded_at: now,
      acceptance_data: Map.delete(attempt.acceptance_data, "payment"),
      last_error: controlled_error(reason),
      operation_token: nil,
      operation_started_at: nil
    )
    |> Repo.update!()
  end

  defp subject_fingerprint(subject) do
    secret = Application.fetch_env!(:dhc, :invitation_acceptance_subject_fingerprint_secret)
    Dhc.Discord.SubjectFingerprint.generate(subject, secret)
  end

  defp controlled_error(%Dhc.Stripe.Error{error: error}) do
    ["stripe", error[:type], error[:code]] |> Enum.reject(&is_nil/1) |> Enum.join(":")
  end

  defp controlled_error({:stripe_api, status, %{"error" => error}}) do
    ["stripe", Integer.to_string(status), error["type"], error["code"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp controlled_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp controlled_error(reason) when is_binary(reason), do: reason
  defp controlled_error({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp controlled_error(_reason), do: "unexpected_error"

  defp stripe_error_summary(%Dhc.Stripe.Error{error: error}), do: Map.take(error, [:type, :code])

  defp stripe_error_summary({:stripe_api, status, %{"error" => error}}),
    do: %{status: status, error: Map.take(error, ["type", "code"])}

  defp stripe_error_summary(_reason), do: %{type: "unexpected_error"}

  # ── Plumbing ─────────────────────────────────────────────────────────

  defp enqueue_recovery(attempt_id) do
    delay = Application.get_env(:dhc, :acceptance_recovery_delay_seconds, 60)

    %{"attempt_id" => attempt_id}
    |> AcceptanceRecoveryWorker.new(schedule_in: delay, replace: [scheduled: [:scheduled_at]])
    |> Oban.insert!()
  end

  defp pending_unexpired_invitation(invitation_id) do
    now = now()

    Repo.one(
      from(i in Invitation,
        where: i.id == ^invitation_id and i.status == "pending" and i.expires_at > ^now
      )
    )
  end

  # Runs `fun` against the locked graph for a handle inside one transaction.
  # Any handle that does not resolve to a consistent graph fails with
  # `failure`, so the browser learns nothing about which row was missing.
  defp with_locked(handle, failure, fun) do
    case cast_uuid(handle) do
      {:ok, continuation_id} ->
        Repo.transaction(fn -> fun.(lock!(continuation_id, failure)) end)

      :error ->
        {:error, failure}
    end
  end

  defp lock!(continuation_id, failure, opts \\ []) do
    case Locked.by_continuation(continuation_id, now(), opts) do
      {:ok, locked} -> locked
      {:error, _reason} -> Repo.rollback(failure)
    end
  end

  defp ensure!(true, _reason), do: :ok
  defp ensure!(false, reason), do: Repo.rollback(reason)

  defp unwrap_nested({:ok, {:ok, view}}), do: {:ok, view}
  defp unwrap_nested({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_nested({:error, reason}), do: {:error, reason}

  defp cast_or(value, failure) do
    case cast_uuid(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, failure}
    end
  end

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value) when is_binary(value), do: String.trim(value)

  defp now do
    :dhc
    |> Application.get_env(:onboarding_acceptance_clock, &DateTime.utc_now/0)
    |> then(fn clock -> clock.() end)
    |> DateTime.truncate(:second)
  end

  defp stripe_adapter do
    Application.get_env(:dhc, :onboarding_stripe_adapter, Dhc.Onboarding.StripeAdapter.Live)
  end

  defp finalizer do
    Application.get_env(:dhc, :onboarding_finalizer, Invitations)
  end
end
