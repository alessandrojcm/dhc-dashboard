defmodule Dhc.Discord do
  @moduledoc """
  Discord server operations owned by the application.

  Callers use this context instead of depending on a Discord client library.
  """

  alias Dhc.Discord.JoinGrant
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo

  import Ecto.Changeset, only: [change: 2, unique_constraint: 3]

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

  defp encrypt_access_token(access_token) do
    Plug.Crypto.encrypt(secret_key_base(), @join_grant_salt, access_token)
  end

  defp secret_key_base, do: DhcWeb.Endpoint.config(:secret_key_base)

  defp adapter, do: Application.fetch_env!(:dhc, :discord_adapter)
  defp guild_id, do: Application.fetch_env!(:dhc, :discord_guild_id)
end
