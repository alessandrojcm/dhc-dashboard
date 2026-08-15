defmodule Dhc.Onboarding.AcceptanceFlow do
  @moduledoc false

  import Ecto.Query

  alias Dhc.Auth.DiscordSubjectLock
  alias Dhc.Auth.Principal
  alias Dhc.Discord.StagedAssignment
  alias Dhc.Invitations
  alias Dhc.Invitations.Invitation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.AttemptState
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordCollisionAuditEvent
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Onboarding.SafeView
  alias Dhc.Repo

  def verify_credentials(invitation_id, email, date_of_birth) do
    if protected_acceptance_started?(invitation_id) do
      {:error, :invalid_credentials}
    else
      Invitations.verify_credentials(invitation_id, email, date_of_birth)
    end
  end

  def start_acceptance(invitation_id, email, date_of_birth) do
    start_acceptance(invitation_id, email, date_of_birth, nil)
  end

  def start_acceptance(invitation_id, email, date_of_birth, protected_continuation_id) do
    with {:ok, invitation_id} <- Ecto.UUID.cast(invitation_id),
         :ok <- Invitations.verify_credentials(invitation_id, email, date_of_birth) do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        invitation =
          from(i in Invitation,
            where: i.id == ^invitation_id and i.status == "pending",
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(invitation), do: Repo.rollback(:invalid_invitation)

        ensure_invitation_eligible!(invitation)

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where:
              a.invitation_id == ^invitation.id and
                a.status in ["processing", "payment_pending", "cleanup_pending", "provisioned"],
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if attempt && not AttemptState.pre_oauth?(attempt), do: Repo.rollback(:invalid_invitation)

        if DateTime.compare(invitation.expires_at, now) != :gt,
          do: Repo.rollback(:invalid_invitation)

        attempt = attempt || insert_pre_oauth_attempt!(invitation)

        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.attempt_id == ^attempt.id and c.status in ["awaiting_oauth", "verified"],
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        continuation =
          if continuation && DateTime.compare(continuation.expires_at, now) == :gt do
            if browser_owns_continuation?(continuation, protected_continuation_id),
              do: continuation,
              else: Repo.rollback(:missing_browser_proof)
          else
            if continuation do
              terminalize_continuation!(
                continuation,
                "expired",
                now,
                continuation.provider_subject
              )
            end

            %InvitationAcceptanceDiscordContinuation{
              invitation_id: invitation.id,
              attempt_id: attempt.id,
              expires_at:
                earliest_expiry(invitation.expires_at, DateTime.add(now, 15 * 60, :second))
            }
            |> Repo.insert!()
          end

        %{
          continuation_id: continuation.id,
          view: SafeView.continuation_state(continuation, invitation)
        }
      end)
    else
      :error -> {:error, :invalid_credentials}
      {:error, _} -> {:error, :invalid_credentials}
    end
  end

  def acceptance_state(continuation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id) do
      Repo.transaction(fn ->
        case lock_continuation_flow(continuation_id) do
          {:ok, invitation, attempt, continuation} ->
            expired? =
              continuation.status in ["awaiting_oauth", "verified"] and
                DateTime.compare(continuation.expires_at, now) != :gt and
                not continuation_consumed_into_attempt?(continuation)

            if expired? do
              terminalize_continuation!(
                continuation,
                "expired",
                now,
                continuation.provider_subject
              )

              if AttemptState.pre_oauth?(attempt),
                do: decline_attempt!(attempt, "discord_expired", now)

              :restart_verification
            else
              case SafeView.acceptance_state(continuation, invitation, attempt, now) do
                {:ok, state} -> state
                {:error, reason} -> Repo.rollback(reason)
              end
            end

          :error ->
            Repo.rollback(:restart_verification)
        end
      end)
    else
      _ -> {:error, :restart_verification}
    end
    |> case do
      {:ok, :restart_verification} -> {:error, :restart_verification}
      {:ok, state} -> {:ok, state}
      _ -> {:error, :restart_verification}
    end
  end

  def continue_acceptance(continuation_id) do
    with {:ok, invitation, attempt} <- consume_verified_continuation(continuation_id) do
      {:ok, SafeView.attempt_state(attempt, invitation)}
    end
  end

  def verify_discord(continuation_id, claims) when is_map(claims) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id),
         subject when is_binary(subject) and subject != "" <- Map.get(claims, "sub") do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        lock_acceptance_advisories!(continuation_id)
        DiscordSubjectLock.lock!(subject)

        {invitation, attempt, continuation} =
          case lock_continuation_flow(continuation_id) do
            {:ok, invitation, attempt, continuation} -> {invitation, attempt, continuation}
            :error -> Repo.rollback(:invalid_continuation)
          end

        if invitation.status != "pending" or attempt.status != "processing",
          do: Repo.rollback(:invalid_continuation)

        cond do
          continuation.status == "verified" and continuation.provider_subject == subject ->
            {:ok, SafeView.continuation_state(continuation, invitation)}

          continuation.status != "awaiting_oauth" or
              DateTime.compare(continuation.expires_at, now) != :gt ->
            {:error, :invalid_continuation}

          identity =
              Repo.one(
                from(e in Dhc.Auth.ExternalIdentity,
                  where:
                    e.provider == "discord" and e.provider_subject == ^subject and
                        is_nil(e.retired_at),
                  lock: "FOR UPDATE"
                )
              ) ->
            terminalize_collision!(
              continuation,
              attempt,
              now,
              subject,
              "external_identity",
              identity.principal_id
            )

            {:error, :collision}

          assignment =
              Repo.one(
                from(a in StagedAssignment,
                  where:
                    a.provider == "discord" and a.provider_subject == ^subject and
                        a.state in ["proposed", "approved"],
                  lock: "FOR UPDATE"
                )
              ) ->
            terminalize_collision!(
              continuation,
              attempt,
              now,
              subject,
              "staged_assignment",
              assignment.principal_id
            )

            {:error, :collision}

          true ->
            claim_id = Ecto.UUID.generate()

            {inserted, _rows} =
              Repo.insert_all(
                InvitationAcceptanceDiscordSubjectClaim,
                [
                  %{
                    id: claim_id,
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

            if inserted == 1 do
              continuation =
                continuation
                |> Ecto.Changeset.change(
                  status: "verified",
                  provider_subject: subject,
                  subject_fingerprint: subject_fingerprint(subject),
                  display_metadata: display_metadata(claims)
                )
                |> Repo.update!()

              {:ok, SafeView.continuation_state(continuation, invitation)}
            else
              terminalize_collision!(
                continuation,
                attempt,
                now,
                subject,
                "active_claim",
                nil
              )

              {:error, :collision}
            end
        end
      end)
      |> case do
        {:ok, {:ok, state}} -> {:ok, state}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_continuation}
    end
  end

  def cancel_discord(continuation_id) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id) do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        lock_acceptance_advisories!(continuation_id)

        {_invitation, attempt, continuation} =
          case lock_continuation_flow(continuation_id) do
            {:ok, invitation, attempt, continuation} -> {invitation, attempt, continuation}
            :error -> Repo.rollback(:invalid_continuation)
          end

        if continuation.status not in ["awaiting_oauth", "verified"] or
             not AttemptState.pre_oauth?(attempt),
           do: Repo.rollback(:invalid_continuation)

        _invitation =
          from(i in Invitation, where: i.id == ^continuation.invitation_id, lock: "FOR UPDATE")
          |> Repo.one!()

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where: a.id == ^continuation.attempt_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        terminalize_continuation!(continuation, "cancelled", now, continuation.provider_subject)
        decline_attempt!(attempt, "discord_cancelled", now)
        %{state: "restartVerification"}
      end)
    else
      _ -> {:error, :invalid_continuation}
    end
  end

  def fail_discord(continuation_id, outcome) when outcome in [:cancelled, :failed] do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id) do
      Repo.transaction(fn ->
        lock_acceptance_advisories!(continuation_id)

        {_invitation, attempt, continuation} =
          case lock_continuation_flow(continuation_id) do
            {:ok, invitation, attempt, continuation} -> {invitation, attempt, continuation}
            :error -> Repo.rollback(:invalid_continuation)
          end

        if continuation.status != "awaiting_oauth" or not AttemptState.pre_oauth?(attempt),
          do: Repo.rollback(:invalid_continuation)

        _invitation =
          from(i in Invitation, where: i.id == ^continuation.invitation_id, lock: "FOR UPDATE")
          |> Repo.one!()

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where: a.id == ^continuation.attempt_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        terminalize_continuation!(
          continuation,
          Atom.to_string(outcome),
          now,
          nil
        )

        decline_attempt!(attempt, "discord_#{outcome}", now)

        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, _reason} -> {:error, :invalid_continuation}
      end
    else
      _ -> {:error, :invalid_continuation}
    end
  end

  def acceptance_oauth_resume_path(continuation_id) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id),
         %InvitationAcceptanceDiscordContinuation{} = continuation <-
           Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id),
         %Invitation{} = invitation <- Repo.get(Invitation, continuation.invitation_id) do
      {:ok, "/members/signup/#{invitation.id}/resume"}
    else
      _ -> {:error, :invalid_continuation}
    end
  end

  @doc false
  def load_consumed_attempt(continuation_id) do
    Repo.transaction(fn ->
      lock_acceptance_advisories!(continuation_id)

      continuation =
        from(c in InvitationAcceptanceDiscordContinuation,
          where: c.id == ^continuation_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      if is_nil(continuation), do: Repo.rollback(:invalid_continuation)

      attempt =
        from(a in InvitationAcceptanceAttempt,
          where: a.id == ^continuation.attempt_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one!()

      invitation = Repo.get!(Invitation, continuation.invitation_id)

      unless Map.get(attempt.acceptance_data, "continuation_id") == continuation.id,
        do: Repo.rollback(:invalid_continuation)

      {invitation, attempt}
    end)
    |> case do
      {:ok, {invitation, attempt}} -> {:ok, invitation, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def active_claim?(continuation) do
    from(c in InvitationAcceptanceDiscordSubjectClaim,
      where:
        c.continuation_id == ^continuation.id and c.provider == "discord" and
          c.provider_subject == ^continuation.provider_subject,
      select: c.id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> is_binary()
  end

  @doc false
  def decline_cleaned_attempt(attempt, reason) do
    Repo.transaction(fn ->
      current =
        attempt
        |> owned_attempt_query()
        |> lock("FOR UPDATE")
        |> Repo.one()

      if is_nil(current) do
        :stale_acceptance_operation
      else
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        continuation = lock_attempt_continuation(current)

        if continuation do
          terminalize_continuation!(continuation, "failed", now, continuation.provider_subject)
        end

        decline_attempt!(current, reason, now)
      end
    end)
  end

  def expire_discord_continuations do
    now = discord_expiry_now()

    expired_ids =
      from(c in InvitationAcceptanceDiscordContinuation,
        where: c.status in ["awaiting_oauth", "verified"] and c.expires_at <= ^now,
        select: c.id
      )
      |> Repo.all()

    expiry_inconsistencies =
      expired_ids
      |> Enum.map(&expire_discord_continuation(&1, now))
      |> Enum.flat_map(fn
        {:inconsistent, continuation_id} -> [continuation_id]
        :ok -> []
      end)

    inconsistent_ids =
      (expiry_inconsistencies ++ inconsistent_claim_continuation_ids())
      |> Enum.uniq()
      |> Enum.sort()

    case inconsistent_ids do
      [] -> {:ok, length(expired_ids)}
      ids -> {:error, {:inconsistent_claims, ids}}
    end
  end

  defp continuation_consumed_into_attempt?(continuation) do
    case Repo.get(InvitationAcceptanceAttempt, continuation.attempt_id) do
      %InvitationAcceptanceAttempt{acceptance_data: data} ->
        Map.get(data, "continuation_id") == continuation.id

      _ ->
        false
    end
  end

  defp discord_expiry_now do
    :dhc
    |> Application.get_env(:onboarding_discord_expiry_clock, &DateTime.utc_now/0)
    |> then(fn clock -> clock.() end)
    |> DateTime.truncate(:second)
  end

  defp insert_pre_oauth_attempt!(invitation) do
    %InvitationAcceptanceAttempt{
      invitation_id: invitation.id,
      acceptance_data: %{},
      stripe_customer_id: prior_customer_id(invitation)
    }
    |> Repo.insert!()
  end

  @doc false
  def ensure_invitation_eligible!(invitation) do
    email = String.downcase(invitation.email)

    principal_exists? =
      Repo.exists?(from(p in Principal, where: fragment("lower(?)", p.email) == ^email))

    member_exists? =
      Repo.exists?(from(m in MemberProfile, where: m.id == ^invitation.prospective_principal_id))

    if principal_exists? or member_exists?, do: Repo.rollback(:invalid_invitation)
  end

  defp prior_customer_id(invitation) do
    from(a in InvitationAcceptanceAttempt,
      where: a.invitation_id == ^invitation.id and not is_nil(a.stripe_customer_id),
      order_by: [desc: a.created_at],
      limit: 1,
      select: a.stripe_customer_id
    )
    |> Repo.one()
    |> Kernel.||(invitation.stripe_customer_id)
  end

  defp earliest_expiry(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp browser_owns_continuation?(continuation, protected_continuation_id) do
    case Ecto.UUID.cast(protected_continuation_id) do
      {:ok, continuation_id} -> continuation.id == continuation_id
      :error -> false
    end
  end

  defp lock_continuation_flow(continuation_id) do
    case Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id) do
      nil ->
        :error

      probe ->
        invitation =
          from(i in Invitation, where: i.id == ^probe.invitation_id, lock: "FOR UPDATE")
          |> Repo.one()

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where: a.id == ^probe.attempt_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.id == ^continuation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if invitation && attempt && continuation &&
             continuation.invitation_id == invitation.id && continuation.attempt_id == attempt.id &&
             attempt.invitation_id == invitation.id do
          {:ok, invitation, attempt, continuation}
        else
          :error
        end
    end
  end

  defp subject_fingerprint(subject) do
    secret = Application.fetch_env!(:dhc, :invitation_acceptance_subject_fingerprint_secret)
    Dhc.Discord.SubjectFingerprint.generate(subject, secret)
  end

  defp consume_verified_continuation(continuation_id) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id) do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        lock_acceptance_advisories!(continuation_id)

        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.id == ^continuation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(continuation), do: Repo.rollback(:invalid_continuation)

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where: a.id == ^continuation.attempt_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        invitation =
          from(i in Invitation,
            where: i.id == ^continuation.invitation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        already_consumed? =
          Map.get(attempt.acceptance_data, "continuation_id") == continuation.id and
            attempt.status in ["processing", "payment_pending", "provisioned", "completed"]

        cond do
          already_consumed? ->
            {invitation, attempt}

          invitation.status != "pending" or attempt.status != "processing" or
            continuation.status != "verified" or
              DateTime.compare(continuation.expires_at, now) != :gt ->
            Repo.rollback(:invalid_continuation)

          not active_claim?(continuation) ->
            Repo.rollback(:invalid_continuation)

          true ->
            attempt =
              attempt
              |> Ecto.Changeset.change(
                acceptance_data:
                  Map.put(attempt.acceptance_data, "continuation_id", continuation.id)
              )
              |> Repo.update!()

            {invitation, attempt}
        end
      end)
      |> case do
        {:ok, {invitation, attempt}} ->
          {:ok, invitation, attempt}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :invalid_continuation}
    end
  end

  defp lock_acceptance_advisories!(continuation_id) do
    continuation = Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id)

    if continuation do
      invitation = Repo.get!(Invitation, continuation.invitation_id)
      DiscordSubjectLock.lock_principal!(invitation.prospective_principal_id)

      if is_binary(continuation.provider_subject) do
        DiscordSubjectLock.lock!(continuation.provider_subject)
      end
    end

    :ok
  end

  defp display_metadata(claims) do
    %{}
    |> maybe_put("username", Map.get(claims, "preferred_username"))
    |> maybe_put("avatarUrl", Map.get(claims, "picture"))
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp terminalize_continuation!(continuation, status, now, subject) do
    if is_binary(subject) and subject != "", do: DiscordSubjectLock.lock!(subject)

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

  defp terminal_subject_fingerprint(_status, subject)
       when is_binary(subject) and subject != "",
       do: subject_fingerprint(subject)

  defp terminal_subject_fingerprint(_status, _subject), do: nil

  defp terminalize_collision!(
         continuation,
         attempt,
         now,
         subject,
         reason_code,
         existing_principal_id
       ) do
    fingerprint = subject_fingerprint(subject)
    terminalize_continuation!(continuation, "collision", now, subject)

    %InvitationAcceptanceDiscordCollisionAuditEvent{
      continuation_id: continuation.id,
      existing_principal_id: existing_principal_id,
      subject_fingerprint: fingerprint,
      reason_code: reason_code,
      created_at: now
    }
    |> Repo.insert!()

    attempt
    |> Ecto.Changeset.change(
      status: "declined",
      concluded_at: now,
      last_error: "discord_collision"
    )
    |> Repo.update!()
  end

  defp protected_acceptance_started?(invitation_id) do
    case Ecto.UUID.cast(invitation_id) do
      {:ok, invitation_id} ->
        Repo.exists?(
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.invitation_id == ^invitation_id
          )
        )

      :error ->
        false
    end
  end

  defp expire_discord_continuation(continuation_id, now) do
    Repo.transaction(fn ->
      continuation_ref = Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id)

      if is_nil(continuation_ref) do
        :ok
      else
        invitation_ref = Repo.get!(Invitation, continuation_ref.invitation_id)
        DiscordSubjectLock.lock_principal!(invitation_ref.prospective_principal_id)

        if is_binary(continuation_ref.provider_subject) do
          DiscordSubjectLock.lock!(continuation_ref.provider_subject)
        end

        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where:
              c.id == ^continuation_id and c.status in ["awaiting_oauth", "verified"] and
                c.expires_at <= ^now,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        _invitation =
          from(i in Invitation,
            where: i.id == ^continuation_ref.invitation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where: a.id == ^continuation_ref.attempt_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        if is_nil(continuation) do
          :ok
        else
          claims =
            from(c in InvitationAcceptanceDiscordSubjectClaim,
              where: c.continuation_id == ^continuation.id,
              lock: "FOR UPDATE"
            )
            |> Repo.all()

          cond do
            recoverable_consumed_continuation?(continuation, attempt) ->
              :ok

            attempt.status != "processing" or not valid_expiry_claim_fence?(continuation, claims) ->
              {:inconsistent, continuation.id}

            true ->
              terminalize_continuation!(
                continuation,
                "expired",
                now,
                continuation.provider_subject
              )

              decline_attempt!(attempt, "discord_expired", now)
              :ok
          end
        end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> {:inconsistent, continuation_id}
    end
  end

  defp recoverable_consumed_continuation?(continuation, attempt) do
    Map.get(attempt.acceptance_data, "continuation_id") == continuation.id and
      attempt.status in ["payment_pending", "cleanup_pending", "provisioned"]
  end

  defp valid_expiry_claim_fence?(%{status: "awaiting_oauth"}, claims), do: claims == []

  defp valid_expiry_claim_fence?(%{status: "verified", provider_subject: subject}, [claim]) do
    is_binary(subject) and subject != "" and claim.provider == "discord" and
      claim.provider_subject == subject
  end

  defp valid_expiry_claim_fence?(_continuation, _claims), do: false

  defp inconsistent_claim_continuation_ids do
    inconsistent_claims =
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

    inconsistent_claims ++ verified_without_claim
  end

  defp lock_attempt_continuation(attempt) do
    continuation_id = Map.get(attempt.acceptance_data, "continuation_id")

    query =
      if continuation_id do
        from(c in InvitationAcceptanceDiscordContinuation,
          where: c.id == ^continuation_id and c.attempt_id == ^attempt.id,
          lock: "FOR UPDATE"
        )
      else
        from(c in InvitationAcceptanceDiscordContinuation,
          where: c.attempt_id == ^attempt.id,
          order_by: [desc: c.created_at],
          limit: 1,
          lock: "FOR UPDATE"
        )
      end

    Repo.one(query)
  end

  defp decline_attempt!(attempt, reason, now) do
    attempt
    |> Ecto.Changeset.change(
      status: "declined",
      concluded_at: now,
      acceptance_data: clear_payment_secrets(attempt.acceptance_data),
      last_error: controlled_error(reason),
      operation_token: nil,
      operation_started_at: nil
    )
    |> Repo.update!()
  end

  defp clear_payment_secrets(data) when is_map(data), do: Map.delete(data, "payment")

  defp controlled_error(%Dhc.Stripe.Error{error: error}) do
    ["stripe", error[:type], error[:code]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
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

  defp owned_attempt_query(%InvitationAcceptanceAttempt{operation_token: nil} = attempt) do
    from(a in InvitationAcceptanceAttempt,
      where: a.id == ^attempt.id and is_nil(a.operation_token)
    )
  end

  defp owned_attempt_query(attempt) do
    from(a in InvitationAcceptanceAttempt,
      where: a.id == ^attempt.id and a.operation_token == ^attempt.operation_token
    )
  end
end
