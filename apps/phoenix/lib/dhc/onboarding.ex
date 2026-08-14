defmodule Dhc.Onboarding do
  @moduledoc """
  Owns the conversion side of Onboarding: Invitation issue, verification,
  read-only pricing, and durable Invitation Acceptance.
  """

  import Ecto.Query

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

  defdelegate verify_credentials(invitation_id, email, date_of_birth), to: Invitations
  defdelegate issue_verification_token(invitation_id, email, date_of_birth), to: Invitations

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
              else: Repo.rollback(:invalid_invitation)
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

        safe_state(continuation)
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
              where: e.provider == "discord" and e.provider_subject == ^subject
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

        terminalize_continuation!(continuation, "cancelled", now, continuation.provider_subject)
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

        terminalize_continuation!(
          continuation,
          Atom.to_string(outcome),
          DateTime.utc_now() |> DateTime.truncate(:second),
          nil
        )

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
        {:ok, safe_state(continuation, invitation)}

      attempt.status == "provisioned" and continuation.status == "verified" ->
        {:ok, safe_attempt_state(attempt, invitation)}

      attempt.status == "processing" and continuation.status in ["awaiting_oauth", "verified"] and
        DateTime.compare(invitation.expires_at, now) == :gt and
          DateTime.compare(continuation.expires_at, now) == :gt ->
        {:ok, safe_state(continuation, invitation)}

      true ->
        {:error, :restart_verification}
    end
  end

  defp safe_attempt_state(%{status: "completed"}, invitation),
    do: %{state: "accepted", invitation_email: invitation.email}

  defp safe_attempt_state(%{status: "payment_pending"}, _invitation),
    do: %{state: "paymentPending"}

  defp safe_attempt_state(%{status: "provisioned"}, _invitation),
    do: %{state: "paymentPending"}

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
            continuation.status != "verified" or
              DateTime.compare(continuation.expires_at, now) != :gt ->
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

    case Invitations.convert_with_discord(
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
        {:error, reason}
    end
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
        if(is_binary(subject) and subject != "", do: subject_fingerprint(subject))
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

      if attempt.status not in ["processing", "payment_pending"],
        do: Repo.rollback(:attempt_not_processing)

      updated =
        attempt
        |> Ecto.Changeset.change(
          status: "provisioned",
          stripe_state: Map.merge(attempt.stripe_state, stripe_state),
          last_error: nil
        )
        |> Repo.update!()

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
    attempt = Repo.get!(InvitationAcceptanceAttempt, attempt.id)

    if stripe_adapter().retryable_failure?(reason) do
      attempt
      |> Ecto.Changeset.change(last_error: inspect(reason))
      |> Repo.update!()
    else
      conclude_failed_attempt(attempt, reason)
    end
  end

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
    attempt = Repo.get!(InvitationAcceptanceAttempt, attempt_id)

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
        attempt
        |> Ecto.Changeset.change(
          status: "declined",
          concluded_at: DateTime.utc_now() |> DateTime.truncate(:second),
          last_error: if(is_binary(reason), do: reason, else: inspect(reason))
        )
        |> Repo.update!()
      else
        attempt
      end
    end)
  end

  defp enqueue_recovery(attempt_id) do
    %{"attempt_id" => attempt_id}
    |> AcceptanceRecoveryWorker.new(
      schedule_in: 60,
      unique: [period: :infinity, fields: [:worker, :args]]
    )
    |> Oban.insert!()
  end

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
