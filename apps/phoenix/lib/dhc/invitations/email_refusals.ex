defmodule Dhc.Invitations.EmailRefusals do
  @moduledoc """
  The one set of email refusals that keeps Waitlist entries and Invitations
  duplicate-proof (ALE-376).

  Waitlist registration and the staff "add a new person" path
  (`Dhc.Waitlist`), Invitation issue (`Dhc.Onboarding.issue_invitation/3`)
  and Invitation re-arming on resend (`Dhc.Invitations`) all ask these
  questions about an email before they write:

    * `:email_is_principal` — the email belongs to a Member or former Member;
    * `:email_has_pending_invitation` — the email has a pending Invitation;
    * `:email_on_waitlist` — the email is on the Waitlist in any standing.

  Each caller decides which questions apply and what it does with the
  answer. Lock-free reads: the unique indexes remain the race backstop.
  """

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.Invitations.Invitation
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @type principal_or_pending :: :email_is_principal | :email_has_pending_invitation

  @doc """
  Refuses an email that belongs to a Principal or that has a pending
  Invitation. `except_invitation_id` names the Invitation being re-armed, so
  it does not count as its own pending duplicate.
  """
  @spec principal_or_pending_invitation(String.t(), Ecto.UUID.t() | nil) ::
          :ok | {:error, principal_or_pending()}
  def principal_or_pending_invitation(email, except_invitation_id \\ nil) do
    cond do
      Repo.exists?(from(p in Principal, where: p.email == ^email)) ->
        {:error, :email_is_principal}

      Repo.exists?(pending_invitation_query(email, except_invitation_id)) ->
        {:error, :email_has_pending_invitation}

      true ->
        :ok
    end
  end

  @doc """
  Refuses an email that is on the Waitlist in any standing, other than as
  the `except_waitlist_id` entry itself (the person an Invitation is for).
  """
  @spec on_waitlist(String.t(), Ecto.UUID.t() | nil) :: :ok | {:error, :email_on_waitlist}
  def on_waitlist(email, except_waitlist_id \\ nil) do
    if Repo.exists?(waitlist_query(email, except_waitlist_id)),
      do: {:error, :email_on_waitlist},
      else: :ok
  end

  @doc """
  The refusals for issuing an Invitation, or re-arming one on resend, to
  `email`: `:email_is_principal`, `:duplicate_pending_invitation` (another
  pending Invitation; `except_invitation_id` is the one being re-armed) and
  `:email_on_waitlist` (any standing, other than the Invitation's own
  `waitlist_id` entry).

  Invitations keep the `:duplicate_pending_invitation` name, which the
  processing log and the Beginners' Workshop `invite` command read.
  """
  @spec invitable(String.t(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) ::
          :ok | {:error, :email_is_principal | :duplicate_pending_invitation | :email_on_waitlist}
  def invitable(email, waitlist_id, except_invitation_id \\ nil) do
    case principal_or_pending_invitation(email, except_invitation_id) do
      :ok -> on_waitlist(email, waitlist_id)
      {:error, :email_has_pending_invitation} -> {:error, :duplicate_pending_invitation}
      {:error, :email_is_principal} = refusal -> refusal
    end
  end

  defp pending_invitation_query(email, nil),
    do: from(i in Invitation, where: i.email == ^email and i.status == "pending")

  defp pending_invitation_query(email, invitation_id),
    do: from(i in pending_invitation_query(email, nil), where: i.id != ^invitation_id)

  defp waitlist_query(email, nil), do: from(w in WaitlistEntry, where: w.email == ^email)

  defp waitlist_query(email, waitlist_id),
    do: from(w in waitlist_query(email, nil), where: w.id != ^waitlist_id)
end
