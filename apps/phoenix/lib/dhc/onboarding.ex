defmodule Dhc.Onboarding do
  @moduledoc """
  Owns the conversion side of Onboarding: Invitation issue, verification,
  read-only pricing, and durable Invitation Acceptance.
  """

  import Ecto.Query
  require Logger

  alias Dhc.Auth.Principal
  alias Dhc.Auth.DiscordSubjectLock
  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Discord.StagedAssignment
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
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
         {:ok, _token} <- Invitations.verify_credentials(invitation_id, email, date_of_birth) do
      Repo.transaction(fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        invitation =
          from(i in Invitation,
            where: i.id == ^invitation_id and i.status == "pending",
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(invitation), do: Repo.rollback(:invalid_invitation)

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where:
              a.invitation_id == ^invitation.id and
                a.status in ["processing", "payment_pending", "cleanup_pending", "provisioned"],
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if attempt && not pre_oauth_attempt?(attempt), do: Repo.rollback(:invalid_invitation)

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
          view: safe_state(continuation)
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

    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id),
         {:ok, %InvitationAcceptanceDiscordContinuation{} = continuation} <-
           load_current_continuation(continuation_id, now),
         %Invitation{} = invitation <- Repo.get(Invitation, continuation.invitation_id),
         %InvitationAcceptanceAttempt{} = attempt <-
           Repo.get(InvitationAcceptanceAttempt, continuation.attempt_id) do
      safe_acceptance_state(continuation, invitation, attempt, now)
    else
      _ -> {:error, :restart_verification}
    end
  end

  @spec continue_acceptance(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def continue_acceptance(continuation_id, attrs) when is_map(attrs) do
    with :ok <- validate_acceptance_details(attrs),
         {:ok, invitation, attempt, advance?} <-
           consume_verified_continuation(continuation_id, attrs) do
      if advance?,
        do: begin_payment(invitation, attempt),
        else: {:ok, safe_attempt_state(attempt, invitation)}
    end
  end

  @spec retry_acceptance(String.t()) :: {:ok, map()} | {:error, term()}
  def retry_acceptance(continuation_id) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id),
         {:ok, invitation, attempt} <- load_consumed_attempt(continuation_id) do
      retry_attempt(invitation, attempt)
    else
      :error -> {:error, :invalid_continuation}
      {:error, _reason} = error -> error
    end
  end

  defp load_current_continuation(continuation_id, now) do
    Repo.transaction(fn ->
      continuation =
        from(c in InvitationAcceptanceDiscordContinuation,
          where: c.id == ^continuation_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(continuation) ->
          :missing

        continuation.status in ["awaiting_oauth", "verified"] and
          DateTime.compare(continuation.expires_at, now) != :gt and
            not continuation_consumed_into_attempt?(continuation) ->
          terminalize_continuation!(
            continuation,
            "expired",
            now,
            continuation.provider_subject
          )

          :expired

        true ->
          continuation
      end
    end)
    |> case do
      {:ok, %InvitationAcceptanceDiscordContinuation{} = continuation} -> {:ok, continuation}
      _ -> {:error, :restart_verification}
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

        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.id == ^continuation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(continuation), do: Repo.rollback(:invalid_continuation)

        invitation =
          from(i in Invitation,
            where: i.id == ^continuation.invitation_id and i.status == "pending",
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where: a.id == ^continuation.attempt_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(invitation) or is_nil(attempt) or attempt.status != "processing",
          do: Repo.rollback(:invalid_continuation)

        DiscordSubjectLock.lock!(subject)

        cond do
          continuation.status == "verified" ->
            {:ok, safe_state(continuation, invitation)}

          continuation.status != "awaiting_oauth" or
              DateTime.compare(continuation.expires_at, now) != :gt ->
            {:error, :invalid_continuation}

          Repo.exists?(
            from(e in Dhc.Auth.ExternalIdentity,
              where:
                e.provider == "discord" and e.provider_subject == ^subject and
                    is_nil(e.retired_at)
            )
          ) ->
            terminalize_collision!(continuation, attempt, now, subject)
            {:error, :collision}

          Repo.exists?(
            from(a in StagedAssignment,
              where:
                a.provider == "discord" and a.provider_subject == ^subject and
                    a.state in ["proposed", "approved"]
            )
          ) ->
            terminalize_collision!(continuation, attempt, now, subject)
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

              {:ok, safe_state(continuation, invitation)}
            else
              terminalize_collision!(continuation, attempt, now, subject)
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

        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.id == ^continuation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(continuation) or continuation.status not in ["awaiting_oauth", "verified"],
          do: Repo.rollback(:invalid_continuation)

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
        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.id == ^continuation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(continuation) or continuation.status != "awaiting_oauth",
          do: Repo.rollback(:invalid_continuation)

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
  def accept(invitation_id, verification_token, next_of_kin_name, next_of_kin_phone, attrs) do
    with :ok <- Invitations.verify_acceptance_token(verification_token, invitation_id),
         {:ok, invitation, attempt} <-
           prepare_attempt(invitation_id, next_of_kin_name, next_of_kin_phone, attrs),
         {:ok, attempt} <- provision_membership(invitation, attempt, attrs) do
      Invitations.convert(
        invitation.id,
        attempt.id,
        next_of_kin_name,
        next_of_kin_phone,
        attempt.stripe_customer_id
      )
    end
  end

  defp prepare_attempt(invitation_id, next_of_kin_name, next_of_kin_phone, payment_attrs) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      invitation =
        from(i in Invitation,
          where: i.id == ^invitation_id and i.status == "pending",
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      if is_nil(invitation), do: Repo.rollback(:invalid_invitation)

      if Repo.exists?(
           from(m in MemberProfile, where: m.id == ^invitation.prospective_principal_id)
         ) do
        Repo.rollback(:invalid_invitation)
      end

      if Repo.exists?(from(p in Principal, where: p.email == ^invitation.email)) do
        Repo.rollback(:invalid_invitation)
      end

      if protected_acceptance_started?(invitation.id) do
        Repo.rollback(:discord_verification_required)
      end

      active_attempt =
        from(a in InvitationAcceptanceAttempt,
          where:
            a.invitation_id == ^invitation.id and
              a.status in ["processing", "cleanup_pending", "provisioned"],
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      if active_attempt && active_attempt.status == "cleanup_pending" do
        Repo.rollback(:payment_cleanup_pending)
      end

      if is_nil(active_attempt) and DateTime.compare(invitation.expires_at, now) != :gt do
        Repo.rollback(:invalid_invitation)
      end

      attempt =
        if active_attempt do
          active_attempt
          |> Ecto.Changeset.change(
            acceptance_data:
              Map.merge(active_attempt.acceptance_data, %{
                "next_of_kin_name" => next_of_kin_name,
                "next_of_kin_phone" => next_of_kin_phone
              })
          )
          |> Repo.update!()
        else
          insert_attempt!(
            invitation,
            acceptance_data(next_of_kin_name, next_of_kin_phone, payment_attrs)
          )
        end

      {invitation, attempt}
    end)
    |> case do
      {:ok, {invitation, attempt}} -> {:ok, invitation, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_attempt!(invitation, acceptance_data) do
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
      acceptance_data: acceptance_data,
      stripe_customer_id: prior_customer_id || invitation.stripe_customer_id
    }
    |> Repo.insert!()
  end

  defp insert_pre_oauth_attempt!(invitation) do
    %InvitationAcceptanceAttempt{invitation_id: invitation.id, acceptance_data: %{}}
    |> Repo.insert!()
  end

  defp pre_oauth_attempt?(attempt) do
    attempt.status == "processing" and attempt.acceptance_data == %{} and
      attempt.stripe_customer_id in [nil, ""] and attempt.stripe_state == %{}
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

  defp safe_state(%{status: "verified"} = continuation, invitation) do
    %{
      state: "discordVerified",
      invitation_email: invitation.email,
      discord: Map.take(continuation.display_metadata, ["username", "avatarUrl"])
    }
  end

  defp safe_state(%{status: "collision"}, _invitation), do: %{state: "discordCollision"}

  defp safe_state(continuation, _invitation) do
    %{state: "awaitingDiscord", expires_at: continuation.expires_at}
  end

  defp safe_state(continuation),
    do: %{
      state: "awaitingDiscord",
      continuation_id: continuation.id,
      expires_at: continuation.expires_at
    }

  defp safe_acceptance_state(continuation, invitation, attempt, now) do
    cond do
      continuation.status == "collision" ->
        {:ok, safe_state(continuation, invitation)}

      attempt.status == "completed" and invitation.status == "accepted" ->
        {:ok, %{state: "accepted", invitation_email: invitation.email}}

      attempt.status == "payment_pending" and continuation.status == "verified" ->
        {:ok, safe_attempt_state(attempt, invitation)}

      attempt.status == "provisioned" and continuation.status == "verified" ->
        {:ok, safe_attempt_state(attempt, invitation)}

      attempt.status == "processing" and continuation.status == "verified" ->
        {:ok, safe_state(continuation, invitation)}

      attempt.status == "processing" and continuation.status == "awaiting_oauth" and
        DateTime.compare(invitation.expires_at, now) == :gt and
          DateTime.compare(continuation.expires_at, now) == :gt ->
        {:ok, safe_state(continuation, invitation)}

      true ->
        {:error, :restart_verification}
    end
  end

  defp safe_attempt_state(%{status: "completed"}, invitation),
    do: %{state: "accepted", invitation_email: invitation.email}

  defp safe_attempt_state(%{status: "payment_pending"} = attempt, _invitation),
    do: %{
      state: "paymentPending",
      discord_verified: true,
      retry_allowed: not is_nil(attempt.last_error)
    }

  defp safe_attempt_state(%{status: "provisioned"}, _invitation),
    do: %{state: "paymentPending", discord_verified: true, retry_allowed: true}

  defp safe_attempt_state(_attempt, _invitation), do: %{state: "restartVerification"}

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

  defp consume_verified_continuation(continuation_id, attrs) do
    with {:ok, continuation_id} <- Ecto.UUID.cast(continuation_id) do
      Repo.transaction(fn ->
        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.id == ^continuation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        if is_nil(continuation), do: Repo.rollback(:invalid_continuation)

        invitation =
          from(i in Invitation,
            where: i.id == ^continuation.invitation_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        attempt =
          from(a in InvitationAcceptanceAttempt,
            where: a.id == ^continuation.attempt_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        already_consumed? =
          Map.get(attempt.acceptance_data, "continuation_id") == continuation.id and
            attempt.status in ["payment_pending", "provisioned", "completed"]

        cond do
          already_consumed? ->
            {invitation, attempt, false}

          invitation.status != "pending" or attempt.status != "processing" or
              continuation.status != "verified" ->
            Repo.rollback(:invalid_continuation)

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
        {:ok, {invitation, attempt, advance?}} ->
          {:ok, invitation, attempt, advance?}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :invalid_continuation}
    end
  end

  defp active_claim?(continuation) do
    Repo.exists?(
      from(c in InvitationAcceptanceDiscordSubjectClaim,
        where:
          c.continuation_id == ^continuation.id and c.provider == "discord" and
            c.provider_subject == ^continuation.provider_subject
      )
    )
  end

  defp load_consumed_attempt(continuation_id) do
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

  defp begin_payment(invitation, attempt) do
    attrs = payment_attrs(attempt)

    with {:ok, requirement} <- stripe_adapter().payment_requirement(attrs.coupon_code),
         {:ok, attempt} <- ensure_customer(invitation, attempt) do
      case requirement do
        :paid -> provision_and_finalize(invitation, attempt, attrs)
        :complimentary -> provision_complimentary(invitation, attempt, attrs.coupon_code)
      end
    else
      {:error, reason} ->
        record_provider_failure(attempt, reason)
        {:error, {:payment_failed, reason}}
    end
  end

  defp provision_complimentary(invitation, attempt, coupon_code) do
    provision_and_finalize(invitation, attempt, %{
      complimentary: true,
      coupon_code: coupon_code
    })
  end

  defp retry_attempt(invitation, %{status: "completed"} = attempt),
    do: {:ok, safe_attempt_state(attempt, invitation)}

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
      |> Map.put(:progress, &record_stripe_progress(attempt.id, &1))

    case stripe_adapter().provision_membership(attrs) do
      {:ok, stripe_state} ->
        with {:ok, attempt} <- mark_provisioned(attempt, stripe_state) do
          finalize_discord(invitation, attempt)
        end

      {:error, reason} ->
        record_provider_failure(attempt, reason)
        {:error, {:payment_failed, reason}}
    end
  end

  defp finalize_discord(invitation, attempt) do
    data = attempt.acceptance_data

    case onboarding_finalizer().convert_with_discord(
           invitation.id,
           attempt.id,
           Map.fetch!(data, "continuation_id"),
           Map.fetch!(data, "next_of_kin_name"),
           Map.fetch!(data, "next_of_kin_phone"),
           attempt.stripe_customer_id
         ) do
      {:ok, _member} ->
        {:ok, %{state: "accepted", invitation_email: invitation.email}}

      {:error, reason} ->
        accepted_after_finalization_race(invitation, attempt, reason)
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
      subject_fingerprint:
        if(status == "failed",
          do: nil,
          else: if(is_binary(subject) and subject != "", do: subject_fingerprint(subject))
        )
    )
    |> Repo.update!()
  end

  defp terminalize_collision!(continuation, attempt, now, subject) do
    terminalize_continuation!(continuation, "collision", now, subject)

    attempt
    |> Ecto.Changeset.change(
      status: "declined",
      concluded_at: now,
      last_error: "discord_collision"
    )
    |> Repo.update!()
  end

  defp subject_fingerprint(subject) do
    secret = Application.fetch_env!(:dhc, :invitation_acceptance_subject_fingerprint_secret)
    :crypto.mac(:hmac, :sha256, secret, subject) |> Base.encode16(case: :lower)
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
    with {:ok, attempt} <- ensure_customer(invitation, attempt),
         {:ok, stripe_state} <-
           stripe_adapter().provision_membership(
             attrs
             |> Map.put(:attempt_id, attempt.id)
             |> Map.put(:invitation_id, invitation.id)
             |> Map.put(:customer_id, attempt.stripe_customer_id)
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
        from(a in InvitationAcceptanceAttempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")
        |> Repo.one!()

      updated =
        case attempt.status do
          status when status in ["processing", "payment_pending"] ->
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

    with {:ok, customer_id} <- stripe_adapter().create_customer(attrs) do
      attempt
      |> Ecto.Changeset.change(stripe_customer_id: customer_id)
      |> Repo.update()
    end
  end

  defp record_provider_failure(attempt, reason) do
    Logger.warning("Stripe progression failed for Invitation Acceptance",
      attempt_id: attempt.id,
      stripe_error: stripe_error_summary(reason)
    )

    attempt = Repo.get!(InvitationAcceptanceAttempt, attempt.id)

    if stripe_adapter().retryable_failure?(reason) do
      attempt
      |> Ecto.Changeset.change(last_error: inspect(reason))
      |> Repo.update!()
    else
      conclude_failed_attempt(attempt, reason)
    end
  end

  defp stripe_error_summary(%Dhc.Stripe.Error{error: error}) do
    Map.take(error, [:type, :code, :param, :message])
  end

  defp stripe_error_summary({:stripe_api, status, %{"error" => error}}) do
    %{status: status, error: Map.take(error, ["type", "code", "param", "message"])}
  end

  defp stripe_error_summary(_reason), do: %{type: "unexpected_error"}

  defp conclude_failed_attempt(attempt, reason) do
    attempt =
      Repo.transaction(fn ->
        attempt =
          from(a in InvitationAcceptanceAttempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")
          |> Repo.one!()

        attempt =
          attempt
          |> Ecto.Changeset.change(status: "cleanup_pending", last_error: inspect(reason))
          |> Repo.update!()

        enqueue_recovery(attempt.id)
        attempt
      end)
      |> then(fn {:ok, attempt} -> attempt end)

    retry_failed_attempt_cleanup(attempt.id)
  end

  @doc false
  def retry_failed_attempt_cleanup(attempt_id) do
    attempt = lock_recovery_context(attempt_id) |> recovery_attempt!()

    if attempt.status == "cleanup_pending" do
      case stripe_adapter().cancel_membership(attempt.stripe_state) do
        :ok ->
          mark_declined(attempt, attempt.last_error)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp mark_declined(attempt, reason) do
    Repo.transaction(fn ->
      attempt =
        from(a in InvitationAcceptanceAttempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")
        |> Repo.one!()

      if attempt.status == "cleanup_pending" do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        continuation = lock_attempt_continuation(attempt)

        if continuation do
          terminalize_continuation!(continuation, "failed", now, continuation.provider_subject)
        end

        decline_attempt!(attempt, reason, now)
      else
        attempt
      end
    end)
  end

  defp enqueue_recovery(attempt_id) do
    %{"attempt_id" => attempt_id}
    |> AcceptanceRecoveryWorker.new(schedule_in: 60)
    |> Oban.insert!()
  end

  @doc false
  def recover_acceptance(attempt_id) do
    case lock_recovery_context(attempt_id) do
      {:ok, %{attempt: %{status: status}}} when status in ["completed", "declined"] ->
        :ok

      {:ok, %{attempt: %{status: "cleanup_pending"} = attempt}} ->
        retry_failed_attempt_cleanup(attempt.id)

      {:ok,
       %{
         attempt: %{status: status} = attempt,
         invitation: invitation,
         continuation: continuation
       }}
      when status in ["payment_pending", "provisioned"] ->
        if continuation do
          retry_attempt(invitation, attempt)
        else
          recover_legacy_attempt(invitation, attempt)
        end

      {:ok, %{attempt: %{status: "processing"}}} ->
        {:error, :payment_not_started}

      {:error, :not_found} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
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
    now = DateTime.utc_now() |> DateTime.truncate(:second)

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
      [] -> :ok
      ids -> {:error, {:inconsistent_claims, ids}}
    end
  end

  defp expire_discord_continuation(continuation_id, now) do
    Repo.transaction(fn ->
      continuation_ref = Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id)

      if is_nil(continuation_ref) do
        :ok
      else
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

        continuation =
          from(c in InvitationAcceptanceDiscordContinuation,
            where:
              c.id == ^continuation_id and c.status in ["awaiting_oauth", "verified"] and
                c.expires_at <= ^now,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

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

  defp lock_recovery_context(attempt_id) do
    Repo.transaction(fn ->
      attempt_ref = Repo.get(InvitationAcceptanceAttempt, attempt_id)

      if is_nil(attempt_ref), do: Repo.rollback(:not_found)

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

      continuation = lock_attempt_continuation(attempt)

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

      %{attempt: attempt, invitation: invitation, continuation: continuation}
    end)
  end

  defp recovery_attempt!({:ok, %{attempt: attempt}}), do: attempt

  defp recovery_attempt!({:error, reason}),
    do: raise("acceptance recovery invariant: #{inspect(reason)}")

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
      last_error: if(is_binary(reason), do: reason, else: inspect(reason))
    )
    |> Repo.update!()
  end

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

  defp record_stripe_progress(attempt_id, progress) when is_map(progress) do
    Repo.transaction(fn ->
      attempt =
        from(a in InvitationAcceptanceAttempt, where: a.id == ^attempt_id, lock: "FOR UPDATE")
        |> Repo.one!()

      attempt
      |> Ecto.Changeset.change(stripe_state: Map.merge(attempt.stripe_state, progress))
      |> Repo.update!()
    end)
    |> case do
      {:ok, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
