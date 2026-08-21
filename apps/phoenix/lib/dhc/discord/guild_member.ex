defmodule Dhc.Discord.GuildMember do
  @moduledoc "A Discord server member normalized independently of the client library."

  @enforce_keys [:user_id, :username, :display_name, :bot, :roles]
  defstruct [
    :user_id,
    :username,
    :global_name,
    :nickname,
    :display_name,
    :avatar,
    :joined_at,
    bot: false,
    roles: []
  ]

  @type t :: %__MODULE__{
          user_id: String.t(),
          username: String.t(),
          global_name: String.t() | nil,
          nickname: String.t() | nil,
          display_name: String.t(),
          avatar: String.t() | nil,
          joined_at: String.t() | nil,
          bot: boolean(),
          roles: [String.t()]
        }

  @doc false
  @spec from_discord(map()) :: t()
  def from_discord(%{"user" => user} = member) do
    nickname = member["nick"]
    global_name = user["global_name"]
    username = Map.fetch!(user, "username")

    %__MODULE__{
      user_id: Map.fetch!(user, "id"),
      username: username,
      global_name: global_name,
      nickname: nickname,
      display_name: nickname || global_name || username,
      avatar: user["avatar"],
      joined_at: member["joined_at"],
      bot: user["bot"] == true,
      roles: member["roles"] || []
    }
  end
end
