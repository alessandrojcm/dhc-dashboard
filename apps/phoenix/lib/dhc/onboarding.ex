defmodule Dhc.Onboarding do
  @moduledoc """
  Owns the conversion side of Onboarding: Invitation issue, verification,
  read-only pricing, and durable Invitation Acceptance.
  """

  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Onboarding.AcceptanceFlow
  alias Dhc.Onboarding.PaymentSubmission

  defdelegate issue_verification_token(invitation_id, email, date_of_birth), to: Invitations
  defdelegate verify_credentials(invitation_id, email, date_of_birth), to: AcceptanceFlow

  @doc """
  Starts the protected pre-payment acceptance journey.

  The returned identifiers are deliberately opaque and must only be retained by
  the browser's protected transport session. They never identify a Principal or
  authorize dashboard access.
  """
  @spec start_acceptance(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :invalid_credentials | :invalid_invitation}
  defdelegate start_acceptance(invitation_id, email, date_of_birth), to: AcceptanceFlow

  @spec start_acceptance(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :invalid_credentials | :invalid_invitation}
  defdelegate start_acceptance(invitation_id, email, date_of_birth, protected_continuation_id),
    to: AcceptanceFlow

  @spec acceptance_state(String.t()) :: {:ok, map()} | {:error, :restart_verification}
  defdelegate acceptance_state(continuation_id), to: AcceptanceFlow

  @spec continue_acceptance(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate continue_acceptance(continuation_id), to: AcceptanceFlow

  @spec submit_payment(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate submit_payment(continuation_id, attrs), to: PaymentSubmission

  @spec retry_acceptance(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate retry_acceptance(continuation_id), to: PaymentSubmission

  @spec verify_discord(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate verify_discord(continuation_id, claims), to: AcceptanceFlow

  @spec verify_discord(String.t(), map(), map()) :: {:ok, map()} | {:error, atom()}
  defdelegate verify_discord(continuation_id, claims, token), to: AcceptanceFlow

  @spec cancel_discord(String.t()) :: {:ok, map()} | {:error, :invalid_continuation}
  defdelegate cancel_discord(continuation_id), to: AcceptanceFlow

  @spec fail_discord(String.t(), :cancelled | :failed) :: :ok | {:error, :invalid_continuation}
  defdelegate fail_discord(continuation_id, outcome), to: AcceptanceFlow

  @spec acceptance_oauth_resume_path(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_continuation}
  defdelegate acceptance_oauth_resume_path(continuation_id), to: AcceptanceFlow

  @spec issue_invitations([map() | String.t()], map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def issue_invitations(invites, user) when is_list(invites) and invites != [] do
    Oban.insert(BulkInviteWorker.new(%{"invites" => invites, "user" => user}))
  end

  @spec pricing(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def pricing(invitation_id, coupon_code \\ nil) do
    PaymentSubmission.pricing(invitation_id, coupon_code)
  end

  @spec accept(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, %{member_id: String.t()}} | {:error, term()}
  defdelegate accept(
                invitation_id,
                continuation_id,
                next_of_kin_name,
                next_of_kin_phone,
                attrs
              ),
              to: PaymentSubmission

  @doc false
  defdelegate retry_failed_attempt_cleanup(attempt_id), to: PaymentSubmission

  @doc false
  defdelegate recover_acceptance(attempt_id), to: PaymentSubmission

  @doc false
  defdelegate reconcile_stripe_event(object), to: PaymentSubmission

  @doc false
  defdelegate expire_discord_continuations(), to: AcceptanceFlow
end
