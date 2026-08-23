defmodule Dhc.Invitations.Repository do
  @moduledoc """
  Repository module for Invitation persistence.

  Keeps the database-facing implementation for bulk Invitation processing behind
  a small interface so workers can focus on orchestration, Stripe, Supabase Auth,
  and email enqueueing.
  """

  import Ecto.Query

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.ProcessingLog
  alias Dhc.Notifications
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.Repository, as: WaitlistRepository
  alias Dhc.Waitlist.WaitlistEntry

  @type invite_data :: map()
  @type invite_result :: map()

  @spec invitation_id_for_issue_key(String.t()) :: {:ok, Ecto.UUID.t()} | :not_found
  def invitation_id_for_issue_key(issue_key) when is_binary(issue_key) do
    from(i in Invitation,
      where: fragment("?->>'issue_key'", i.metadata) == ^issue_key,
      select: i.id
    )
    |> Repo.one()
    |> case do
      nil -> :not_found
      invitation_id -> {:ok, invitation_id}
    end
  end

  @doc """
  Resolves a waitlist ID into the invite shape accepted by bulk Invitation processing.

  The returned shape is the same as the controller's `InvitationCreateInvite`
  (`firstName`, `lastName`, `email`, `phoneNumber`, `dateOfBirth`); the worker
  uses it to fill in the invitation row at issue time. Under ALE-162, the
  waitlist's `user_profiles` row stays untouched at issue — it is read for
  invite data, not modified.
  """
  @spec get_waitlist_invite_data(String.t()) :: {:ok, invite_data()} | {:error, term()}
  def get_waitlist_invite_data(waitlist_id) when is_binary(waitlist_id) do
    query =
      from up in UserProfile,
        join: w in WaitlistEntry,
        on: w.id == up.waitlist_id,
        where: up.waitlist_id == ^waitlist_id,
        select: %{
          "firstName" => up.first_name,
          "lastName" => up.last_name,
          "email" => w.email,
          "dateOfBirth" => up.date_of_birth,
          "phoneNumber" => up.phone_number
        }

    case Repo.one(query) do
      nil -> {:error, {:waitlist_not_found, waitlist_id}}
      invite_data -> {:ok, invite_data}
    end
  end

  @doc """
  Inserts a pending Invitation and returns its ID.

  ALE-162 (ADR 0010): issue time is side-effect free — this function mints a
  fresh Phoenix UUID for `invitation.prospective_principal_id` (the eventual Principal id) and
  stores the date of birth on the invitation row so `verify_credentials` can
  match without a `user_profiles` row. It does **not** call Supabase Auth,
  create a Stripe customer, or insert a `user_profiles` row. All of that moves
  into acceptance; pricing remains read-only.

  `original_invite` is preserved only to detect waitlist-id invites and read
  the optional `invitationType` / `metadata` from `invite_data`.

  Rejects the invite while a pending Invitation exists for the email
  (case-insensitive; the column is `citext`). Re-inviting becomes possible
  again only once the pending Invitation expires or is revoked. The partial
  unique index `invitations_email_pending_unique` stays as the concurrency
  backstop: two racing inserts can never both win.
  """
  @spec create_invitation_record(map() | String.t(), invite_data(), String.t() | nil) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  def create_invitation_record(original_invite, invite_data, created_by_id) do
    waitlist_id =
      if is_binary(original_invite), do: original_invite, else: Map.get(invite_data, "waitlistId")

    Repo.transaction(fn ->
      with :ok <- ensure_no_pending_invitation(invite_data["email"]),
           {:ok, invitation_id} <-
             insert_pending_invitation(invite_data, waitlist_id, created_by_id) do
        invitation_id
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, invitation_id} -> {:ok, invitation_id}
      {:error, reason} -> {:error, {:create_invitation, reason}}
    end
  end

  # Sequential duplicate defense: a friendly rejection instead of relying on
  # the partial unique index. Concurrent invites are still arbitrated by the
  # index itself (`invitations_email_pending_unique`).
  defp ensure_no_pending_invitation(email) when is_binary(email) do
    pending? =
      from(i in Invitation, where: i.email == ^email and i.status == "pending")
      |> Repo.exists?()

    if pending?, do: {:error, :duplicate_pending_invitation}, else: :ok
  end

  @doc """
  Inserts a pending Invitation and returns its ID.

  Mints a fresh Phoenix UUID for `prospective_principal_id` (the eventual Principal id). Under
  ALE-162 this is not an `auth.users` id; the auth.users FK was dropped and
  acceptance will create the Principal with this id.
  """
  @spec insert_pending_invitation(invite_data(), String.t() | nil, String.t() | nil) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  def insert_pending_invitation(invite_data, waitlist_id, created_by_id) do
    invitation = %Invitation{
      id: Ecto.UUID.generate(),
      email: invite_data["email"],
      prospective_principal_id: Ecto.UUID.generate(),
      waitlist_id: waitlist_id,
      status: "pending",
      expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
      created_by_principal_id: created_by_id,
      invitation_type: Map.get(invite_data, "invitationType", "admin"),
      pricing_tier: Map.get(invite_data, "pricingTier", "standard"),
      metadata: Map.get(invite_data, "metadata"),
      first_name: invite_data["firstName"],
      last_name: invite_data["lastName"],
      phone_number: invite_data["phoneNumber"],
      date_of_birth: parse_date(invite_data["dateOfBirth"])
    }

    case Repo.insert(invitation) do
      {:ok, invitation} -> {:ok, invitation.id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Ecto.ConstraintError, Postgrex.Error] -> {:error, error}
  end

  @doc """
  Marks a waitlist entry as invited when an Invitation was created from it.
  """
  @spec mark_waitlist_invited(String.t()) :: :ok
  def mark_waitlist_invited(waitlist_id) when is_binary(waitlist_id) do
    WaitlistRepository.mark_invited(waitlist_id)
  end

  @doc """
  Stores the bulk Invitation processing log.
  """
  @spec store_processing_results([invite_result()], String.t()) :: :ok | {:error, term()}
  def store_processing_results(results, created_by_id) when is_list(results) do
    success_count = Enum.count(results, & &1.success)
    failure_count = length(results) - success_count

    log = %ProcessingLog{
      principal_id: created_by_id,
      total_count: length(results),
      success_count: success_count,
      failure_count: failure_count,
      results: %{"items" => results},
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case Repo.insert(log) do
      {:ok, _log} -> :ok
      {:error, reason} -> {:error, {:processing_log, reason}}
    end
  rescue
    error in [Ecto.ConstraintError, Postgrex.Error] -> {:error, {:processing_log, error}}
  end

  @doc """
  Creates the admin Notification summarising a bulk Invitation run.
  """
  @spec create_processing_notification([invite_result()], String.t()) :: :ok | {:error, term()}
  def create_processing_notification(results, created_by_id) when is_list(results) do
    success_count = Enum.count(results, & &1.success)
    failure_count = length(results) - success_count

    body =
      if failure_count == 0 do
        "Successfully processed #{success_count} invitations out of #{length(results)}"
      else
        "Successfully processed #{success_count} invitations out of #{length(results)}, failed to process #{failure_count} invitations"
      end

    case Notifications.create(created_by_id, body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:notification, reason}}
    end
  end

  @doc """
  Normalises supported date shapes into the date string accepted by Postgres.
  """
  @spec date_string(Date.t() | DateTime.t() | String.t() | term()) :: String.t()
  def date_string(%Date{} = date), do: Date.to_iso8601(date)
  def date_string(%DateTime{} = date_time), do: DateTime.to_date(date_time) |> Date.to_iso8601()

  def date_string(value) when is_binary(value) do
    value
    |> String.split("T")
    |> List.first()
  end

  def date_string(value), do: to_string(value)

  defp parse_date(%Date{} = date), do: date
  defp parse_date(%DateTime{} = date_time), do: DateTime.to_date(date_time)

  defp parse_date(value) when is_binary(value) and value != "" do
    value
    |> String.split("T")
    |> List.first()
    |> Date.from_iso8601!()
  end

  defp parse_date(_value), do: nil
end
