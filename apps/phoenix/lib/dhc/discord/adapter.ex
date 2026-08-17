defmodule Dhc.Discord.Adapter do
  @moduledoc false

  alias Dhc.Discord.{ApiError, GuildMember}

  @type list_members_result :: {:ok, [GuildMember.t()]} | {:error, ApiError.t() | term()}
  @type add_member_result ::
          {:ok, :added | :already_member} | {:error, ApiError.t() | term()}
  @type kick_member_result :: :ok | {:error, ApiError.t() | term()}

  @callback list_guild_members(guild_id :: String.t()) :: list_members_result()

  @callback add_guild_member(
              guild_id :: String.t(),
              user_id :: String.t(),
              access_token :: String.t()
            ) :: add_member_result()

  @callback kick_guild_member(
              guild_id :: String.t(),
              user_id :: String.t(),
              reason :: String.t()
            ) :: kick_member_result()
end
