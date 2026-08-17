defmodule Dhc.Discord do
  @moduledoc """
  Discord server operations owned by the application.

  Callers use this context instead of depending on a Discord client library.
  """

  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Discord.JoinGrant
  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo

  import Ecto.Changeset, only: [change: 2, unique_constraint: 3]
  import Ecto.Query

  @join_grant_salt "discord join grant:v1"

  @spec list_guild_members() :: Dhc.Discord.Adapter.list_members_result()
  def list_guild_members do
    adapter().list_guild_members(guild_id())
  end

  @spec add_guild_member(String.t(), String.t()) :: Dhc.Discord.Adapter.add_member_result()
  def add_guild_member(user_id, access_token) do
    adapter().add_guild_member(guild_id(), user_id, access_token)
  end

  @spec kick_guild_member(String.t(), String.t()) :: Dhc.Discord.Adapter.kick_member_result()
  def kick_guild_member(user_id, reason) do
    adapter().kick_guild_member(guild_id(), user_id, reason)
  end

  @spec create_join_grant(Ecto.UUID.t(), map()) ::
          {:ok, JoinGrant.t()} | {:error, :invalid_token | Ecto.Changeset.t()}
  def create_join_grant(continuation_id, token) when is_map(token) do
    with %{"access_token" => access_token, "expires_in" => expires_in}
         when is_binary(access_token) and access_token != "" and is_integer(expires_in) and
                expires_in > 0 <- token,
         %InvitationAcceptanceDiscordContinuation{} = continuation <-
           Repo.get(InvitationAcceptanceDiscordContinuation, continuation_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %JoinGrant{}
      |> change(%{
        continuation_id: continuation.id,
        attempt_id: continuation.attempt_id,
        encrypted_access_token: encrypt_access_token(access_token),
        expires_at: DateTime.add(now, expires_in, :second)
      })
      |> unique_constraint(:continuation_id,
        name: :discord_join_grants_continuation_id_index
      )
      |> Repo.insert()
    else
      _invalid -> {:error, :invalid_token}
    end
  end

  def create_join_grant(_continuation_id, _token), do: {:error, :invalid_token}

  @spec join_grant_access_token(JoinGrant.t()) ::
          {:ok, String.t()} | {:error, :unavailable | :invalid}
  def join_grant_access_token(%JoinGrant{encrypted_access_token: nil}),
    do: {:error, :unavailable}

  def join_grant_access_token(%JoinGrant{encrypted_access_token: encrypted_access_token}) do
    case Plug.Crypto.decrypt(secret_key_base(), @join_grant_salt, encrypted_access_token) do
      {:ok, access_token} when is_binary(access_token) -> {:ok, access_token}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  @spec zeroize_join_grant(JoinGrant.t()) :: {:ok, JoinGrant.t()} | {:error, Ecto.Changeset.t()}
  def zeroize_join_grant(%JoinGrant{} = grant) do
    grant
    |> change(encrypted_access_token: nil)
    |> Repo.update()
  end

  @spec cleanup_expired_join_grants() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired_join_grants do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expired = from(grant in JoinGrant, where: grant.expires_at <= ^now)

    Repo.transaction(fn ->
      Repo.update_all(expired, set: [encrypted_access_token: nil, updated_at: now])
      {deleted_count, _grants} = Repo.delete_all(expired)
      deleted_count
    end)
  end

  @spec prepare_guild_join(Ecto.UUID.t()) ::
          {:ok, %{grant: JoinGrant.t(), user_id: String.t(), access_token: String.t()}}
          | {:terminal, atom()}
          | {:error, atom()}
  def prepare_guild_join(grant_id) do
    case Repo.get(JoinGrant, grant_id) do
      nil ->
        {:terminal, :grant_not_found}

      grant ->
        prepare_existing_guild_join(grant)
    end
  end

  defp prepare_existing_guild_join(grant) do
    if DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt do
      with {:ok, access_token} <- join_grant_access_token(grant),
           {:ok, user_id} <- discord_user_id_for_grant(grant) do
        {:ok, %{grant: grant, user_id: user_id, access_token: access_token}}
      else
        {:error, :unavailable} -> {:terminal, :grant_unavailable}
        {:error, :invalid} -> terminalize_grant(grant, :invalid_grant)
        {:error, reason} -> {:error, reason}
      end
    else
      terminalize_grant(grant, :grant_expired)
    end
  end

  defp discord_user_id_for_grant(grant) do
    query =
      from(identity in ExternalIdentity,
        join: attempt in InvitationAcceptanceAttempt,
        on: attempt.id == ^grant.attempt_id,
        join: invitation in Invitation,
        on: invitation.id == attempt.invitation_id,
        where:
          identity.principal_id == invitation.prospective_principal_id and
            identity.provider == "discord" and is_nil(identity.retired_at),
        select: identity.provider_subject
      )

    case Repo.one(query) do
      user_id when is_binary(user_id) -> {:ok, user_id}
      nil -> {:error, :discord_identity_not_found}
    end
  end

  defp terminalize_grant(grant, reason) do
    case zeroize_join_grant(grant) do
      {:ok, _grant} -> {:terminal, reason}
      {:error, _changeset} -> {:error, :grant_zeroization_failed}
    end
  end

  defp encrypt_access_token(access_token) do
    Plug.Crypto.encrypt(secret_key_base(), @join_grant_salt, access_token)
  end

  defp secret_key_base, do: DhcWeb.Endpoint.config(:secret_key_base)

  defp adapter, do: Application.fetch_env!(:dhc, :discord_adapter)
  defp guild_id, do: Application.fetch_env!(:dhc, :discord_guild_id)
end
