defmodule Dhc.Onboarding do
  @moduledoc """
  Owns the conversion side of Onboarding: Invitation issue, verification,
  read-only pricing, and durable Invitation Acceptance.
  """

  import Ecto.Query
  require Logger

  alias Dhc.Auth.DiscordSubjectLock
  alias Dhc.Auth.Principal
  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Discord.StagedAssignment
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.AttemptState
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordCollisionAuditEvent
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Onboarding.SafeView
  alias Dhc.Onboarding.Workers.AcceptanceRecoveryWorker
  alias Dhc.Repo

  defdelegate issue_verification_token(invitation_id, email, date_of_birth), to: Invitations

  def verify_credentials(invitation_id, email, date_of_birth) do
    if protected_acceptance_started?(invitation_id) do
      {:error, :invalid_credentials}
    else
      Invitations.verify_credentials(invitation_id, email, date_of_birth)
    end
  end

  @doc """
  Starts the protected pre-payment acceptance journey.

  The returned identifiers are deliberately opaque and must only be retained by
  the browser's protected transport session. They never identify a Principal or
  authorize dashboard access.
  """
  @spec start_acceptance(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :invalid_credentials | :invalid_invitation}
  def start_acceptance(invitation_id, email, date_of_birth) do
    start_acceptance(invitation_id, email, date_of_birth, nil)
  end

  @spec start_acceptance(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :invalid_credentials | :invalid_invitation}
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

  @spec acceptance_state(String.t()) :: {:ok, map()} | {:error, :restart_verification}
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

  @spec continue_acceptance(String.t()) :: {:ok, map()} | {:error, term()}
  def continue_acceptance(continuation_id) do
    with {:ok, invitation, attempt} <- consume_verified_continuation(continuation_id) do
      {:ok, SafeView.attempt_state(attempt, invitation)}
    end
  end

  @spec submit_payment(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def submit_payment(continuation_id, attrs) when is_map(attrs) do
    with :ok <- validate_acceptance_details(attrs),
         {:ok, invitation, attempt, advance?} <-
           record_payment_submission(continuation_id, attrs) do
      if advance?,
        do: run_acceptance_operation(attempt.id, :automatic),
        else: {:ok, SafeView.attempt_state(attempt, invitation)}
    end
  end

  @spec retry_acceptance(String.t()) :: {:ok, map()} | {:error, term()}
  def retry_acceptance(continuation_id) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id),
         {:ok, _invitation, attempt} <- load_consumed_attempt(continuation_id) do
      run_acceptance_operation(attempt.id, :explicit)
    else
      :error -> {:error, :invalid_continuation}
      {:error, _reason} = error -> error
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

  @spec verify_discord(String.t(), map()) :: {:ok, map()} | {:error, atom()}
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

  @spec cancel_discord(String.t()) :: {:ok, map()} | {:error, :invalid_continuation}
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

  @spec fail_discord(String.t(), :cancelled | :failed) :: :ok | {:error, :invalid_continuation}
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

  defp discord_expiry_now do
    :dhc
    |> Application.get_env(:onboarding_discord_expiry_clock, &DateTime.utc_now/0)
    |> then(fn clock -> clock.() end)
    |> DateTime.truncate(:second)
  end

  @spec acceptance_oauth_resume_path(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_continuation}
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

  @spec issue_invitations([map() | String.t()], map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def issue_invitations(invites, user) when is_list(invites) and invites != [] do
    Oban.insert(BulkInviteWorker.new(%{"invites" => invites, "user" => user}))
  end

  @spec pricing(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def pricing(invitation_id, coupon_code \\ nil) do
    with {:ok, %Invitation{}} <- pending_invitation(invitation_id) do
      stripe_adapter().preview_membership(coupon_code)
    end
  end

  @spec accept(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, %{member_id: String.t()}} | {:error, term()}
  def accept(invitation_id, continuation_id, next_of_kin_name, next_of_kin_phone, attrs) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id),
         {:ok, invitation, attempt, progression} <-
           prepare_attempt(
             invitation_id,
             continuation_id,
             next_of_kin_name,
             next_of_kin_phone,
             attrs
           ),
         {:ok, attempt} <- maybe_provision_membership(progression, invitation, attempt, attrs) do
      Invitations.convert(
        invitation.id,
        attempt.id,
        continuation_id,
        next_of_kin_name,
        next_of_kin_phone,
        attempt.stripe_customer_id
      )
    else
      :error -> {:error, :discord_verification_required}
      error -> error
    end
  end

  defp insert_pre_oauth_attempt!(invitation) do
    %InvitationAcceptanceAttempt{
      invitation_id: invitation.id,
      acceptance_data: %{},
      stripe_customer_id: prior_customer_id(invitation)
    }
    |> Repo.insert!()
  end

  defp prepare_attempt(
         invitation_id,
         continuation_id,
         next_of_kin_name,
         next_of_kin_phone,
         payment_attrs
       ) do
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

      active_attempt =
        from(a in InvitationAcceptanceAttempt,
          where:
            a.invitation_id == ^invitation.id and
              a.status in [
                "processing",
                "stripe_progressing",
                "payment_pending",
                "cleanup_pending",
                "provisioned"
              ],
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      if active_attempt && active_attempt.status == "cleanup_pending" do
        Repo.rollback(:payment_cleanup_pending)
      end

      if is_nil(active_attempt), do: Repo.rollback(:discord_verification_required)

      continuation =
        from(c in InvitationAcceptanceDiscordContinuation,
          where:
            c.id == ^continuation_id and c.invitation_id == ^invitation.id and
              c.attempt_id == ^active_attempt.id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      proof_already_consumed =
        not is_nil(continuation) and
          active_attempt.acceptance_data["discord_continuation_id"] == continuation.id

      if is_nil(continuation) or continuation.status != "verified" or
           (not proof_already_consumed and DateTime.compare(continuation.expires_at, now) != :gt) or
           (active_attempt.acceptance_data != %{} and not proof_already_consumed),
         do: Repo.rollback(:discord_verification_required)

      DiscordSubjectLock.lock!(continuation.provider_subject)

      claim =
        from(c in InvitationAcceptanceDiscordSubjectClaim,
          where:
            c.continuation_id == ^continuation.id and c.provider == "discord" and
              c.provider_subject == ^continuation.provider_subject,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      if is_nil(claim), do: Repo.rollback(:discord_verification_required)

      if active_attempt.status == "stripe_progressing",
        do: Repo.rollback(:acceptance_in_progress)

      updated_acceptance_data =
        if active_attempt.acceptance_data == %{} do
          acceptance_data(next_of_kin_name, next_of_kin_phone, payment_attrs)
          |> Map.put("discord_continuation_id", continuation.id)
        else
          active_attempt.acceptance_data
        end

      {attempt, progression} =
        if active_attempt.status == "provisioned" do
          {active_attempt, :provisioned}
        else
          attempt =
            active_attempt
            |> Ecto.Changeset.change(
              status: "stripe_progressing",
              acceptance_data: updated_acceptance_data,
              last_error: nil
            )
            |> Repo.update!()

          {attempt, :claimed}
        end

      {invitation, attempt, progression}
    end)
    |> case do
      {:ok, {invitation, attempt, progression}} ->
        {:ok, invitation, attempt, progression}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_invitation_eligible!(invitation) do
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

  defp validate_acceptance_details(attrs) do
    if present?(Map.get(attrs, :next_of_kin_name)) and
         present?(Map.get(attrs, :next_of_kin_phone)) and
         present?(Map.get(attrs, :confirmation_token)) do
      :ok
    else
      {:error, :invalid_acceptance_details}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

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

  defp record_payment_submission(continuation_id, attrs) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id) do
      Repo.transaction(fn ->
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
          from(i in Invitation, where: i.id == ^continuation.invitation_id, lock: "FOR UPDATE")
          |> Repo.one!()

        already_submitted? =
          Map.get(attempt.acceptance_data, "continuation_id") == continuation.id and
            attempt.status in ["payment_pending", "provisioned", "completed"]

        cond do
          already_submitted? ->
            {invitation, attempt, false}

          invitation.status != "pending" or attempt.status != "processing" or
            not AttemptState.payment_ready?(attempt) or continuation.status != "verified" or
              not active_claim?(continuation) ->
            Repo.rollback(:invalid_continuation)

          true ->
            payment_attrs = %{
              confirmation_token: attrs.confirmation_token,
              coupon_code: blank_to_nil(Map.get(attrs, :coupon_code)),
              mandate_context: Map.get(attrs, :mandate_context, %{})
            }

            acceptance_data =
              acceptance_data(
                String.trim(attrs.next_of_kin_name),
                String.trim(attrs.next_of_kin_phone),
                payment_attrs
              )
              |> Map.put("continuation_id", continuation.id)

            attempt =
              attempt
              |> Ecto.Changeset.change(
                status: "payment_pending",
                acceptance_data: acceptance_data,
                stripe_state: Map.put(attempt.stripe_state, "payment_operation_started", true)
              )
              |> Repo.update!()

            enqueue_recovery(attempt.id)

            {invitation, attempt, true}
        end
      end)
      |> case do
        {:ok, {invitation, attempt, advance?}} -> {:ok, invitation, attempt, advance?}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_continuation}
    end
  end

  defp active_claim?(continuation) do
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

  defp load_consumed_attempt(continuation_id) do
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

  defp begin_payment(_invitation, attempt) do
    attrs = payment_attrs(attempt)

    with {:ok, _invitation, attempt} <- revalidate_payment_fence(attempt.id),
         {:ok, attempt, payment_plan} <- ensure_payment_plan(attempt, attrs.coupon_code),
         {:ok, invitation, attempt} <- revalidate_payment_fence(attempt.id),
         {:ok, attempt} <- ensure_customer(invitation, attempt) do
      case payment_plan.requirement do
        :paid ->
          provision_and_finalize(invitation, attempt, Map.put(attrs, :payment_plan, payment_plan))

        :complimentary ->
          provision_complimentary(invitation, attempt, attrs.coupon_code, payment_plan)
      end
    else
      {:error, reason} ->
        retryable? = stripe_adapter().retryable_failure?(reason)
        record_provider_failure(attempt, reason)

        if retryable?,
          do: {:error, {:provider_unavailable, reason}},
          else: {:error, {:payment_failed, reason}}
    end
  end

  defp provision_complimentary(invitation, attempt, coupon_code, payment_plan) do
    provision_and_finalize(invitation, attempt, %{
      complimentary: true,
      coupon_code: coupon_code,
      payment_plan: payment_plan
    })
  end

  defp retry_attempt(invitation, %{status: "completed"} = attempt),
    do: {:ok, SafeView.attempt_state(attempt, invitation)}

  defp retry_attempt(invitation, %{status: "provisioned"} = attempt),
    do: finalize_discord(invitation, attempt)

  defp retry_attempt(invitation, %{status: "payment_pending"} = attempt) do
    begin_payment(invitation, attempt)
  end

  defp retry_attempt(_invitation, _attempt), do: {:error, :invalid_attempt}

  defp provision_and_finalize(invitation, attempt, attrs) do
    attrs =
      attrs
      |> Map.put(:attempt_id, attempt.id)
      |> Map.put(:invitation_id, invitation.id)
      |> Map.put(:customer_id, attempt.stripe_customer_id)
      |> Map.put(:stripe_state, attempt.stripe_state)
      |> Map.put(:fence, fn -> payment_progression_allowed?(attempt.id) end)
      |> Map.put(:progress, &record_stripe_progress(attempt.id, attempt.operation_token, &1))

    with {:ok, _invitation, _attempt} <- revalidate_payment_fence(attempt.id) do
      stripe_adapter().provision_membership(attrs)
    end
    |> case do
      {:ok, stripe_state} ->
        with {:ok, attempt} <- mark_provisioned(attempt, stripe_state) do
          finalize_discord(invitation, attempt)
        end

      {:pending, %{"payment_intent_status" => "processing"} = stripe_state} ->
        with {:ok, attempt} <- mark_provisioned(attempt, stripe_state) do
          finalize_discord(invitation, attempt)
        end

      {:pending, stripe_state} ->
        with :ok <- record_stripe_progress(attempt.id, attempt.operation_token, stripe_state),
             {:ok, _invitation, current_attempt} <- revalidate_payment_fence(attempt.id) do
          {:ok, SafeView.attempt_state(current_attempt, invitation)}
        end

      {:error, reason} ->
        retryable? = stripe_adapter().retryable_failure?(reason)
        record_provider_failure(attempt, reason)

        if retryable?,
          do: {:error, {:provider_unavailable, reason}},
          else: {:error, {:payment_failed, reason}}
    end
  end

  defp finalize_discord(invitation, attempt) do
    data = attempt.acceptance_data

    continuation_id =
      Map.get(data, "continuation_id") || Map.fetch!(data, "discord_continuation_id")

    case onboarding_finalizer().convert_with_discord(
           invitation.id,
           attempt.id,
           continuation_id,
           Map.fetch!(data, "next_of_kin_name"),
           Map.fetch!(data, "next_of_kin_phone"),
           attempt.stripe_customer_id,
           attempt.operation_token
         ) do
      {:ok, _member} ->
        {:ok, %{state: "accepted", invitation_email: invitation.email}}

      {:error, reason} ->
        case accepted_after_finalization_race(invitation, attempt, reason) do
          {:ok, _state} = accepted ->
            accepted

          {:error, original_reason} ->
            release_operation_error(attempt, "local_finalization_failed")
            {:error, original_reason}
        end
    end
  end

  defp accepted_after_finalization_race(invitation, attempt, original_reason) do
    Repo.transaction(fn ->
      current_invitation =
        from(i in Invitation, where: i.id == ^invitation.id, lock: "FOR UPDATE")
        |> Repo.one!()

      current_attempt =
        from(a in InvitationAcceptanceAttempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")
        |> Repo.one!()

      if current_invitation.status == "accepted" and current_attempt.status == "completed" do
        {:ok, %{state: "accepted", invitation_email: current_invitation.email}}
      else
        {:error, original_reason}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp onboarding_finalizer do
    Application.get_env(:dhc, :onboarding_finalizer, Invitations)
  end

  defp ensure_payment_plan(attempt, coupon_code) do
    case Map.get(attempt.stripe_state, "payment_plan") do
      plan when is_map(plan) ->
        {:ok, attempt, deserialize_payment_plan(plan)}

      _ ->
        with {:ok, plan} <- stripe_adapter().prepare_payment(coupon_code),
             {:ok, attempt} <- persist_payment_plan(attempt.id, plan) do
          {:ok, attempt, plan}
        end
    end
  end

  defp persist_payment_plan(attempt_id, plan) do
    Repo.transaction(fn ->
      with {:ok, _invitation, attempt} <- lock_payment_fence(attempt_id) do
        attempt
        |> Ecto.Changeset.change(
          stripe_state:
            Map.put(attempt.stripe_state, "payment_plan", serialize_payment_plan(plan))
        )
        |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, attempt} -> {:ok, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp serialize_payment_plan(plan) do
    %{
      "requirement" => Atom.to_string(plan.requirement),
      "monthly_price_id" => plan.monthly_price_id,
      "annual_price_id" => plan.annual_price_id,
      "promotion_code_id" => plan.promotion_code_id,
      "migration" => plan.migration?
    }
  end

  defp deserialize_payment_plan(plan) do
    %{
      requirement:
        if(Map.get(plan, "requirement") == "complimentary", do: :complimentary, else: :paid),
      monthly_price_id: Map.fetch!(plan, "monthly_price_id"),
      annual_price_id: Map.fetch!(plan, "annual_price_id"),
      promotion_code_id: Map.get(plan, "promotion_code_id"),
      migration?: Map.get(plan, "migration", false)
    }
  end

  defp release_operation_error(attempt, error_code) do
    Repo.transaction(fn ->
      current =
        attempt
        |> owned_attempt_query()
        |> where(
          [a],
          a.status in ["stripe_progressing", "payment_pending", "provisioned", "cleanup_pending"]
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      if current do
        status =
          if current.status == "stripe_progressing", do: "payment_pending", else: current.status

        current
        |> Ecto.Changeset.change(
          status: status,
          last_error: error_code,
          operation_token: nil,
          operation_started_at: nil
        )
        |> Repo.update!()
      end
    end)

    :ok
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value) when is_binary(value), do: String.trim(value)

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

  defp maybe_provision_membership(:provisioned, _invitation, attempt, _attrs),
    do: {:ok, attempt}

  defp maybe_provision_membership(:claimed, invitation, attempt, attrs),
    do: provision_membership(invitation, attempt, attrs)

  defp provision_membership(
         _invitation,
         %InvitationAcceptanceAttempt{status: "provisioned"} = attempt,
         _attrs
       ),
       do: {:ok, attempt}

  defp provision_membership(invitation, attempt, _attrs) do
    attrs = payment_attrs(attempt)

    if attrs.confirmation_token in [nil, ""] do
      {:error, {:payment_failed, :stripe_confirmation_token_required}}
    else
      provision_membership_with_attrs(invitation, attempt, attrs)
    end
  end

  defp provision_membership_with_attrs(invitation, attempt, attrs) do
    with {:ok, attempt, payment_plan} <- ensure_payment_plan(attempt, attrs.coupon_code),
         {:ok, attempt} <- ensure_customer(invitation, attempt),
         {:ok, stripe_state} <-
           stripe_adapter().provision_membership(
             attrs
             |> Map.put(:attempt_id, attempt.id)
             |> Map.put(:invitation_id, invitation.id)
             |> Map.put(:customer_id, attempt.stripe_customer_id)
             |> Map.put(:payment_plan, payment_plan)
             |> Map.put(:progress, &record_stripe_progress(attempt.id, &1))
           ) do
      mark_provisioned(attempt, stripe_state)
    else
      {:error, reason} ->
        record_provider_failure(attempt, reason)
        {:error, {:payment_failed, reason}}
    end
  end

  defp mark_provisioned(attempt, stripe_state) do
    Repo.transaction(fn ->
      attempt =
        if AttemptState.discord_bound?(attempt) do
          case lock_payment_fence(attempt.id) do
            {:ok, _invitation, current_attempt}
            when current_attempt.operation_token == attempt.operation_token ->
              current_attempt

            {:error, reason} ->
              Repo.rollback(reason)

            _ ->
              Repo.rollback(:stale_acceptance_operation)
          end
        else
          attempt
          |> owned_attempt_query()
          |> lock("FOR UPDATE")
          |> Repo.one()
        end

      if is_nil(attempt), do: Repo.rollback(:stale_acceptance_operation)

      updated =
        case attempt.status do
          status when status in ["processing", "payment_pending", "stripe_progressing"] ->
            attempt
            |> Ecto.Changeset.change(
              status: "provisioned",
              stripe_state: Map.merge(attempt.stripe_state, stripe_state),
              last_error: nil
            )
            |> Repo.update!()

          "provisioned" ->
            attempt
            |> Ecto.Changeset.change(stripe_state: Map.merge(attempt.stripe_state, stripe_state))
            |> Repo.update!()

          _status ->
            Repo.rollback(:attempt_not_processing)
        end

      enqueue_recovery(updated.id)

      updated
    end)
  end

  defp ensure_customer(
         _invitation,
         %InvitationAcceptanceAttempt{stripe_customer_id: id} = attempt
       )
       when is_binary(id) and id != "",
       do: {:ok, attempt}

  defp ensure_customer(
         %Invitation{stripe_customer_id: id},
         %InvitationAcceptanceAttempt{} = attempt
       )
       when is_binary(id) and id != "" do
    attempt
    |> Ecto.Changeset.change(stripe_customer_id: id)
    |> Repo.update()
  end

  defp ensure_customer(invitation, attempt) do
    name =
      [invitation.first_name, invitation.last_name]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    attrs = %{
      email: invitation.email,
      name: name,
      invited_by_id: invitation.created_by_principal_id || invitation.prospective_principal_id,
      attempt_id: attempt.id,
      idempotency_key: "invitation-acceptance-attempt:#{attempt.id}:customer"
    }

    with {:ok, _attempt} <- revalidate_customer_attempt(attempt),
         {:ok, customer_id} <- stripe_adapter().create_customer(attrs),
         {:ok, current_attempt} <- revalidate_customer_attempt(attempt) do
      if current_attempt.stripe_customer_id in [nil, ""] do
        current_attempt
        |> Ecto.Changeset.change(stripe_customer_id: customer_id)
        |> Repo.update()
      else
        {:ok, current_attempt}
      end
    end
  end

  defp record_provider_failure(attempt, reason) do
    Logger.warning("Stripe progression failed for Invitation Acceptance",
      attempt_id: attempt.id,
      stripe_error: stripe_error_summary(reason)
    )

    record_active_provider_failure(attempt, reason)
  end

  defp record_active_provider_failure(attempt, reason) do
    if stripe_adapter().retryable_failure?(reason) do
      release_operation_error(attempt, controlled_error(reason))
    else
      conclude_failed_attempt(attempt, reason)
    end
  end

  defp stripe_error_summary(%Dhc.Stripe.Error{error: error}) do
    Map.take(error, [:type, :code])
  end

  defp stripe_error_summary({:stripe_api, status, %{"error" => error}}) do
    %{status: status, error: Map.take(error, ["type", "code"])}
  end

  defp stripe_error_summary(_reason), do: %{type: "unexpected_error"}

  defp conclude_failed_attempt(attempt, reason) do
    result =
      Repo.transaction(fn ->
        current =
          attempt
          |> owned_attempt_query()
          |> lock("FOR UPDATE")
          |> Repo.one()

        if is_nil(current), do: Repo.rollback(:stale_acceptance_operation)

        current =
          current
          |> Ecto.Changeset.change(
            status: "cleanup_pending",
            last_error: controlled_error(reason),
            operation_token: nil,
            operation_started_at: nil
          )
          |> Repo.update!()

        enqueue_recovery(current.id)
        current
      end)

    case result do
      {:ok, current} -> retry_failed_attempt_cleanup(current.id)
      {:error, :stale_acceptance_operation} -> :ok
    end
  end

  @doc false
  def retry_failed_attempt_cleanup(attempt_id) do
    run_acceptance_operation(attempt_id, :automatic)
  end

  defp cleanup_attempt(attempt) do
    cleanup_state =
      attempt.stripe_state
      |> Map.put("acceptance_attempt_id", attempt.id)
      |> Map.put("customer_id", attempt.stripe_customer_id)

    case stripe_adapter().cancel_membership(cleanup_state) do
      :ok ->
        mark_declined(attempt, attempt.last_error)
        :ok

      {:error, reason} ->
        release_operation_error(attempt, "stripe_cleanup_unavailable")
        {:error, reason}
    end
  end

  defp mark_declined(attempt, reason) do
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

  defp enqueue_recovery(attempt_id) do
    delay = Application.get_env(:dhc, :acceptance_recovery_delay_seconds, 60)

    %{"attempt_id" => attempt_id}
    |> AcceptanceRecoveryWorker.new(
      schedule_in: delay,
      replace: [scheduled: [:scheduled_at]]
    )
    |> Oban.insert!()
  end

  @doc false
  def recover_acceptance(attempt_id) do
    run_acceptance_operation(attempt_id, :automatic)
  end

  @doc false
  def reconcile_stripe_event(object) when is_map(object) do
    customer_id =
      case Map.get(object, "customer") do
        id when is_binary(id) -> id
        %{"id" => id} -> id
        _ -> nil
      end

    if is_binary(customer_id) and customer_id != "" do
      from(a in InvitationAcceptanceAttempt,
        where:
          a.stripe_customer_id == ^customer_id and
            a.status in ["payment_pending", "cleanup_pending", "provisioned"],
        select: a.id
      )
      |> Repo.all()
      |> Enum.each(&enqueue_recovery/1)
    end

    :ok
  end

  @doc false
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

  defp run_acceptance_operation(attempt_id, mode) do
    case acquire_recovery_operation(attempt_id, mode) do
      {:ok, %{attempt: %{status: status}}} when status in ["completed", "declined"] ->
        :ok

      {:ok, %{attempt: %{status: "cleanup_pending"} = attempt}} ->
        cleanup_attempt(attempt)

      {:ok, %{attempt: attempt, invitation: invitation, continuation: continuation}}
      when attempt.status in ["payment_pending", "provisioned"] ->
        if continuation,
          do: retry_attempt(invitation, attempt),
          else: recover_legacy_attempt(invitation, attempt)

      {:ok, %{attempt: %{status: "processing"}}} ->
        {:error, :payment_not_started}

      {:error, :not_found} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acquire_recovery_operation(attempt_id, mode) do
    Repo.transaction(fn ->
      attempt_ref = Repo.get(InvitationAcceptanceAttempt, attempt_id)

      if is_nil(attempt_ref), do: Repo.rollback(:not_found)

      invitation_ref = Repo.get!(Invitation, attempt_ref.invitation_id)
      continuation_ref = attempt_continuation(attempt_ref)

      DiscordSubjectLock.lock_principal!(invitation_ref.prospective_principal_id)

      if continuation_ref && is_binary(continuation_ref.provider_subject) do
        DiscordSubjectLock.lock!(continuation_ref.provider_subject)
      end

      continuation = lock_attempt_continuation(attempt_ref)

      invitation =
        from(i in Invitation, where: i.id == ^attempt_ref.invitation_id, lock: "FOR UPDATE")
        |> Repo.one!()

      attempt =
        from(a in InvitationAcceptanceAttempt,
          where: a.id == ^attempt_id and a.invitation_id == ^invitation.id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      if is_nil(attempt), do: Repo.rollback(:not_found)

      if mode == :explicit and not AttemptState.retry_allowed?(attempt),
        do: Repo.rollback(:retry_not_allowed)

      if AttemptState.lease_active?(attempt), do: Repo.rollback(:operation_in_progress)

      if continuation && attempt.status in ["payment_pending", "cleanup_pending", "provisioned"] do
        if continuation.status != "verified" or is_nil(continuation.provider_subject),
          do: Repo.rollback(:inconsistent_discord_continuation)

        claim =
          from(c in InvitationAcceptanceDiscordSubjectClaim,
            where:
              c.continuation_id == ^continuation.id and c.provider == "discord" and
                c.provider_subject == ^continuation.provider_subject,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(claim), do: Repo.rollback(:inconsistent_discord_claim)
      end

      attempt =
        if attempt.status in ["payment_pending", "cleanup_pending", "provisioned"] do
          attempt
          |> Ecto.Changeset.change(
            operation_token: Ecto.UUID.generate(),
            operation_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )
          |> Repo.update!()
        else
          attempt
        end

      %{attempt: attempt, invitation: invitation, continuation: continuation}
    end)
  end

  defp attempt_continuation(attempt) do
    continuation_id = Map.get(attempt.acceptance_data, "continuation_id")

    if continuation_id,
      do: Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id),
      else:
        Repo.one(
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.attempt_id == ^attempt.id,
            order_by: [desc: c.created_at],
            limit: 1
          )
        )
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

  defp recover_legacy_attempt(invitation, %{status: "provisioned"} = attempt) do
    data = attempt.acceptance_data

    Invitations.convert(
      invitation.id,
      attempt.id,
      data["next_of_kin_name"],
      data["next_of_kin_phone"],
      attempt.stripe_customer_id
    )
  end

  defp recover_legacy_attempt(invitation, %{status: "payment_pending"} = attempt),
    do: begin_payment(invitation, attempt)

  defp record_stripe_progress(attempt_id, progress),
    do: record_stripe_progress(attempt_id, nil, progress)

  defp record_stripe_progress(attempt_id, operation_token, progress) when is_map(progress) do
    Repo.transaction(fn ->
      query =
        from(a in InvitationAcceptanceAttempt,
          where:
            a.id == ^attempt_id and
              a.status in ["processing", "stripe_progressing", "payment_pending", "provisioned"]
        )

      query =
        if operation_token do
          from(a in query, where: a.operation_token == ^operation_token)
        else
          query
        end

      snapshot = Repo.one(query)

      attempt =
        if snapshot && AttemptState.discord_bound?(snapshot) do
          case lock_payment_fence(attempt_id) do
            {:ok, _invitation, current_attempt}
            when is_nil(operation_token) or current_attempt.operation_token == operation_token ->
              current_attempt

            {:error, reason} ->
              Repo.rollback(reason)

            _ ->
              Repo.rollback(:stale_acceptance_operation)
          end
        else
          from(a in query, lock: "FOR UPDATE") |> Repo.one()
        end

      if is_nil(attempt), do: Repo.rollback(:stale_acceptance_operation)

      attempt
      |> Ecto.Changeset.change(stripe_state: Map.merge(attempt.stripe_state, progress))
      |> Repo.update!()
    end)
    |> case do
      {:ok, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp payment_progression_allowed?(attempt_id) do
    case revalidate_payment_fence(attempt_id) do
      {:ok, _invitation, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp revalidate_customer_attempt(attempt) do
    if AttemptState.discord_bound?(attempt) do
      case revalidate_payment_fence(attempt.id) do
        {:ok, _invitation, current_attempt}
        when current_attempt.operation_token == attempt.operation_token ->
          {:ok, current_attempt}

        {:ok, _invitation, _current_attempt} ->
          {:error, :stale_acceptance_operation}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case Repo.get(InvitationAcceptanceAttempt, attempt.id) do
        %InvitationAcceptanceAttempt{status: status} = current
        when status in ["processing", "payment_pending", "stripe_progressing"] ->
          {:ok, current}

        _ ->
          {:error, :attempt_not_processing}
      end
    end
  end

  defp revalidate_payment_fence(attempt_id) do
    Repo.transaction(fn ->
      case lock_payment_fence(attempt_id) do
        {:ok, invitation, attempt} -> {invitation, attempt}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {invitation, attempt}} -> {:ok, invitation, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  # Lock ordering follows ADR-0019: Continuation, Attempt, Invitation, then Claim.
  # The initial unlocked Attempt read discovers the opaque Continuation id only;
  # every authorization fact is re-read under the ordered locks below.
  defp lock_payment_fence(attempt_id) do
    with %InvitationAcceptanceAttempt{} = snapshot <-
           Repo.get(InvitationAcceptanceAttempt, attempt_id),
         continuation_id when is_binary(continuation_id) <-
           Map.get(snapshot.acceptance_data, "continuation_id") ||
             Map.get(snapshot.acceptance_data, "discord_continuation_id"),
         %InvitationAcceptanceDiscordContinuation{} = continuation <-
           from(c in InvitationAcceptanceDiscordContinuation,
             where: c.id == ^continuation_id,
             lock: "FOR UPDATE"
           )
           |> Repo.one(),
         %InvitationAcceptanceAttempt{} = attempt <-
           from(a in InvitationAcceptanceAttempt, where: a.id == ^attempt_id, lock: "FOR UPDATE")
           |> Repo.one(),
         %Invitation{} = invitation <-
           from(i in Invitation, where: i.id == ^attempt.invitation_id, lock: "FOR UPDATE")
           |> Repo.one(),
         %InvitationAcceptanceDiscordSubjectClaim{} = claim <-
           from(c in InvitationAcceptanceDiscordSubjectClaim,
             where: c.continuation_id == ^continuation.id,
             lock: "FOR UPDATE"
           )
           |> Repo.one(),
         true <- continuation.attempt_id == attempt.id,
         true <- continuation.invitation_id == invitation.id,
         true <- continuation.status == "verified",
         true <- attempt.status in ["payment_pending", "stripe_progressing"],
         true <- invitation.status == "pending",
         true <- claim.provider == "discord",
         true <- claim.provider_subject == continuation.provider_subject do
      {:ok, invitation, attempt}
    else
      _ -> {:error, :payment_fence_invalid}
    end
  end

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

  defp acceptance_data(next_of_kin_name, next_of_kin_phone, attrs) do
    mandate_context = Map.get(attrs, :mandate_context, %{})

    %{
      "next_of_kin_name" => next_of_kin_name,
      "next_of_kin_phone" => next_of_kin_phone,
      "payment" => %{
        "confirmation_token" => Map.get(attrs, :confirmation_token),
        "coupon_code" => Map.get(attrs, :coupon_code),
        "mandate_context" => %{
          "ip_address" => Map.get(mandate_context, :ip_address),
          "user_agent" => Map.get(mandate_context, :user_agent)
        }
      }
    }
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

  defp pending_invitation(invitation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.one(
           from(i in Invitation,
             where: i.id == ^invitation_id and i.status == "pending" and i.expires_at > ^now
           )
         ) do
      nil -> {:error, :not_found}
      invitation -> {:ok, invitation}
    end
  end

  defp stripe_adapter do
    Application.get_env(:dhc, :onboarding_stripe_adapter, Dhc.Onboarding.StripeAdapter.Live)
  end
end
