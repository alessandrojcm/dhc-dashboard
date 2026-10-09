defmodule Dhc.Onboarding do
  @moduledoc """
  Owns the conversion side of Onboarding: Invitation issue and credential
  verification.

  The browser-facing acceptance session lives behind an opaque handle in
  `Dhc.Onboarding.Acceptance`; controllers and workers call that module
  directly. This module keeps the Invitation-level operations that are not
  part of one browser's session.
  """

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.Email.Worker, as: EmailWorker
  alias Dhc.Invitations
  alias Dhc.Invitations.BulkInviteWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Repository
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @invite_email_template "inviteMember"
  @required_invite_fields ~w(firstName lastName email phoneNumber dateOfBirth)
  @pricing_tiers ~w(standard coach student)

  @doc """
  Verifies public Invitation credentials without issuing bearer material.

  Once a protected acceptance session has started for the Invitation, this
  compatibility check refuses so the credentials cannot be probed outside the
  session.
  """
  @spec verify_credentials(String.t(), String.t(), String.t() | Date.t()) ::
          :ok | {:error, :invalid_credentials}
  def verify_credentials(invitation_id, email, date_of_birth) do
    if protected_acceptance_started?(invitation_id),
      do: {:error, :invalid_credentials},
      else: Invitations.verify_credentials(invitation_id, email, date_of_birth)
  end

  @doc """
  Enqueues a bulk direct-Invitation job; each invite is issued through
  `issue_invitation/3` by `Dhc.Invitations.BulkInviteWorker`.
  """
  @spec issue_invitations([map()], map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def issue_invitations(invites, user) when is_list(invites) and invites != [] do
    Oban.insert(BulkInviteWorker.new(%{"invites" => invites, "user" => user}))
  end

  @doc """
  The one synchronous single-Invitation issue function (ALE-376).

  Runs **inside the caller's transaction** (it raises outside one) so the
  Invitation commits or rolls back with the caller's own writes: the bulk
  worker wraps each invite in its own transaction, and the Beginners'
  Workshop `invite` command moves the Waitlist standing to `invited` in the
  same one. It inserts a pending Invitation (`standard` tier unless the
  invite names one, 7-day expiry), queues the `inviteMember` email and
  writes the invite's processing-log entry.

  `invite` is the string-keyed invite shape (`firstName`, `lastName`,
  `email`, `phoneNumber`, `dateOfBirth`, optional `pricingTier`,
  `invitationType` and `metadata`). Pass `waitlist_id:` when the Invitation
  is for a Waitlist person; the caller owns that person's eligibility and
  standing.

  Refused, writing nothing, with:

    * `{:invalid_invite, fields}` for missing fields or an unknown tier;
    * `:duplicate_pending_invitation` while the email has a pending Invitation;
    * `:email_is_principal` when the email belongs to a Member or former Member;
    * `:email_on_waitlist` when the email is on the Waitlist in any standing,
      other than as the `waitlist_id` entry itself.

  Callers record a refusal with `record_refused_invitation/3` after their
  transaction rolls back.
  """
  @spec issue_invitation(map(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{invitation_id: Ecto.UUID.t(), email: String.t()}} | {:error, term()}
  def issue_invitation(invite, created_by_id, opts \\ []) when is_map(invite) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "Dhc.Onboarding.issue_invitation/3 must run inside a transaction"
    end

    waitlist_id = Keyword.get(opts, :waitlist_id)

    with {:ok, invite} <- validate_invite(invite),
         :ok <- ensure_issuable(invite["email"], waitlist_id),
         {:ok, invitation_id} <-
           Repository.insert_pending_invitation(invite, waitlist_id, created_by_id),
         :ok <- enqueue_invitation_email(invite, invitation_id),
         :ok <-
           Repository.store_processing_results(
             [%{email: invite["email"], success: true, invitationId: invitation_id}],
             created_by_id
           ) do
      {:ok, %{invitation_id: invitation_id, email: invite["email"]}}
    end
  end

  @doc """
  Records a refused Invitation in the processing log. Call it outside the
  rolled-back issue transaction so the entry survives.
  """
  @spec record_refused_invitation(String.t() | nil, term(), Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def record_refused_invitation(email, reason, created_by_id) do
    Repository.store_processing_results(
      [%{email: email || "unknown", success: false, error: inspect(reason)}],
      created_by_id
    )
  end

  defp validate_invite(invite) do
    missing = Enum.reject(@required_invite_fields, &present?(&1, invite[&1]))
    invalid_tier? = invite["pricingTier"] not in [nil, "" | @pricing_tiers]

    cond do
      missing != [] -> {:error, {:invalid_invite, missing}}
      invalid_tier? -> {:error, {:invalid_invite, ["pricingTier"]}}
      true -> {:ok, Map.update!(invite, "email", &normalize_email/1)}
    end
  end

  defp present?("dateOfBirth", %Date{}), do: true

  defp present?("dateOfBirth", value) when is_binary(value),
    do: match?({:ok, _date}, value |> Repository.date_string() |> Date.from_iso8601())

  defp present?(_field, value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_field, _value), do: false

  # The pending check is a friendly sequential refusal; two racing issues
  # are still arbitrated by `invitations_email_pending_unique`.
  defp ensure_issuable(email, waitlist_id) do
    cond do
      Repo.exists?(from(i in Invitation, where: i.email == ^email and i.status == "pending")) ->
        {:error, :duplicate_pending_invitation}

      Repo.exists?(from(p in Principal, where: p.email == ^email)) ->
        {:error, :email_is_principal}

      on_waitlist_elsewhere?(email, waitlist_id) ->
        {:error, :email_on_waitlist}

      true ->
        :ok
    end
  end

  defp on_waitlist_elsewhere?(email, nil),
    do: Repo.exists?(from(w in WaitlistEntry, where: w.email == ^email))

  defp on_waitlist_elsewhere?(email, waitlist_id),
    do: Repo.exists?(from(w in WaitlistEntry, where: w.email == ^email and w.id != ^waitlist_id))

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()

  defp enqueue_invitation_email(invite, invitation_id) do
    args = %{
      "email" => invite["email"],
      "transactional_id" => @invite_email_template,
      "data_variables" =>
        %{
          "INVITEE_FIRST_NAME" => invite["firstName"],
          "INVITEE_LAST_NAME" => invite["lastName"],
          "INVITATION_LINK" => invitation_link(invite, invitation_id),
          "INSURANCE_FORM_LINK" => Dhc.Members.insurance_form().link
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }

    case Oban.insert(EmailWorker.new(args)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:email_enqueue, reason}}
    end
  end

  defp invitation_link(invite, invitation_id) do
    :dhc
    |> Application.fetch_env!(:app_url)
    |> URI.merge("/members/signup/#{invitation_id}")
    |> Map.put(
      :query,
      URI.encode_query(%{
        "dateOfBirth" => Repository.date_string(invite["dateOfBirth"]),
        "email" => invite["email"]
      })
    )
    |> URI.to_string()
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
end
