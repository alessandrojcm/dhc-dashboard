defmodule Dhc.Onboarding do
  @moduledoc """
  Owns the conversion side of Onboarding: Invitation issue, verification,
  read-only pricing, and durable Invitation Acceptance.
  """

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.Workers.AcceptanceRecoveryWorker
  alias Dhc.Repo

  defdelegate verify_credentials(invitation_id, email, date_of_birth), to: Invitations
  defdelegate issue_verification_token(invitation_id, email, date_of_birth), to: Invitations

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

      if attempt.status != "processing", do: Repo.rollback(:attempt_not_processing)

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
