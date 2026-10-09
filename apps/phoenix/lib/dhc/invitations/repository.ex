defmodule Dhc.Invitations.Repository do
  @moduledoc """
  Repository module for Invitation persistence.

  Keeps the database-facing implementation for Invitation issue behind a small
  interface; `Dhc.Onboarding.issue_invitation/3` owns the issue rules.
  """

  import Ecto.Query

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.ProcessingLog
  alias Dhc.Notifications
  alias Dhc.Repo

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
  Writes one Invitation processing-log entry over `results`.
  `Dhc.Onboarding` writes one entry per issued or refused invite.
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
