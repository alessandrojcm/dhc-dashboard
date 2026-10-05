defmodule Dhc.Discord.Adapter do
  @moduledoc false

  alias Dhc.Discord.{ApiError, GuildMember}

  @type list_members_result :: {:ok, [GuildMember.t()]} | {:error, ApiError.t() | term()}
  @type add_member_result ::
          {:ok, :added | :already_member} | {:error, ApiError.t() | term()}
  @type kick_member_result :: :ok | {:error, ApiError.t() | term()}

  @type message_params :: %{
          required(:content) => String.t(),
          optional(:allowed_mentions) => map(),
          optional(:nonce) => String.t() | integer()
        }
  @type thread_params :: %{
          required(:name) => String.t(),
          optional(:auto_archive_duration) => 60 | 1_440 | 4_320 | 10_080
        }
  @type message_result ::
          {:ok, %{message_id: String.t()}} | {:error, ApiError.t() | term()}
  @type thread_result ::
          {:ok, %{thread_id: String.t()}} | {:error, ApiError.t() | term()}

  @callback list_guild_members(guild_id :: String.t()) :: list_members_result()

  @callback add_guild_member(
              guild_id :: String.t(),
              user_id :: String.t(),
              access_token :: String.t(),
              nickname :: String.t()
            ) :: add_member_result()

  @callback kick_guild_member(
              guild_id :: String.t(),
              user_id :: String.t(),
              reason :: String.t()
            ) :: kick_member_result()

  @callback create_message(
              channel_id :: String.t(),
              params :: message_params()
            ) :: message_result()

  @callback create_thread_from_message(
              channel_id :: String.t(),
              message_id :: String.t(),
              params :: thread_params()
            ) :: thread_result()
end
