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
  alias Dhc.Notifications.Repository, as: NotificationsRepository
  alias Dhc.Repo
  alias Dhc.UserProfiles.Repository, as: UserProfilesRepository
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.Repository, as: WaitlistRepository
  alias Dhc.Waitlist.WaitlistEntry

  @type invite_data :: map()
  @type invite_result :: map()

  @doc """
  Resolves a waitlist ID into the invite shape accepted by bulk Invitation processing.
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
  Creates the pending Invitation and supporting user profile state.

  Existing pending Invitations for the same email are expired before the new
  Invitation is inserted.
  """
  @spec create_invitation_record(
          map() | String.t(),
          invite_data(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  def create_invitation_record(original_invite, invite_data, user_id, customer_id, created_by_id) do
    waitlist_id =
      if is_binary(original_invite), do: original_invite, else: Map.get(invite_data, "waitlistId")

    with :ok <- expire_pending_for_email(invite_data["email"]),
         {:ok, _profile} <-
           UserProfilesRepository.upsert_invited_profile(
             invite_data,
             user_id,
             customer_id,
             waitlist_id
           ),
         {:ok, invitation_id} <-
           insert_pending_invitation(invite_data, user_id, waitlist_id, created_by_id) do
      {:ok, invitation_id}
    else
      {:error, reason} -> {:error, {:create_invitation, reason}}
    end
  end

  @doc """
  Expires pending Invitations for an email address.
  """
  @spec expire_pending_for_email(String.t()) :: :ok
  def expire_pending_for_email(email) when is_binary(email) do
    from(i in Invitation, where: i.email == ^email and i.status == "pending")
    |> Repo.update_all(
      set: [status: "expired", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    :ok
  end

  @doc """
  Inserts a pending Invitation and returns its ID.
  """
  @spec insert_pending_invitation(invite_data(), String.t(), String.t() | nil, String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  def insert_pending_invitation(invite_data, user_id, waitlist_id, created_by_id) do
    invitation = %Invitation{
      email: invite_data["email"],
      user_id: user_id,
      waitlist_id: waitlist_id,
      status: "pending",
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day),
      created_by: created_by_id,
      invitation_type: Map.get(invite_data, "invitationType", "admin"),
      metadata: Map.get(invite_data, "metadata")
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
      user_id: created_by_id,
      total_count: length(results),
      success_count: success_count,
      failure_count: failure_count,
      results: results,
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

    case NotificationsRepository.create(created_by_id, body) do
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
end
