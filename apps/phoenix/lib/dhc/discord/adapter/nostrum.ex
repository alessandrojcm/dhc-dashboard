defmodule Dhc.Discord.Adapter.Nostrum do
  @moduledoc false

  @behaviour Dhc.Discord.Adapter

  alias Dhc.Discord.{ApiError, GuildMember}
  alias Nostrum.Api
  alias Nostrum.Error.ApiError, as: NostrumApiError

  @page_size 1_000

  @impl true
  def list_guild_members(guild_id) do
    with {:ok, guild_id} <- cast_snowflake(guild_id, "guild id") do
      fetch_member_pages(guild_id, nil, [])
    end
  end

  @impl true
  def add_guild_member(guild_id, user_id, access_token, nickname) do
    with {:ok, guild_id} <- cast_snowflake(guild_id, "guild id"),
         {:ok, user_id} <- cast_snowflake(user_id, "user id") do
      options = [access_token: access_token, nick: nickname]

      case Nostrum.Api.Guild.add_member(guild_id, user_id, options) do
        {:ok, %Nostrum.Struct.Guild.Member{}} -> {:ok, :added}
        {:ok} -> {:ok, :already_member}
        {:error, error} -> {:error, normalize_error(error)}
      end
    end
  end

  @impl true
  def kick_guild_member(guild_id, user_id, reason) do
    with {:ok, guild_id} <- cast_snowflake(guild_id, "guild id"),
         {:ok, user_id} <- cast_snowflake(user_id, "user id"),
         :ok <- validate_audit_reason(reason) do
      case Nostrum.Api.Guild.kick_member(guild_id, user_id, reason) do
        {:ok} -> :ok
        {:error, error} -> {:error, normalize_error(error)}
      end
    end
  end

  @valid_archive_durations [60, 1440, 4320, 10_080]

  @impl true
  def create_message(channel_id, params) when is_map(params) do
    with {:ok, channel_id} <- cast_snowflake(channel_id, "channel id"),
         {:ok, body} <- message_body(params) do
      # NOTE: `Nostrum.Api.Message.create/2` is deliberately bypassed here.
      # Its `prepare_allowed_mentions/1` helper crashes on verbatim Discord
      # payloads such as `%{parse: ["everyone"]}`, and this seam must forward
      # `allowed_mentions` untouched — the caller owns mention policy.
      case Api.request(:post, Nostrum.Constants.channel_messages(channel_id), body) do
        {:ok, response_body} -> decode_message_id(response_body)
        {:error, error} -> {:error, normalize_error(error)}
      end
    end
  end

  @impl true
  def create_thread_from_message(channel_id, message_id, params) when is_map(params) do
    with {:ok, channel_id} <- cast_snowflake(channel_id, "channel id"),
         {:ok, message_id} <- cast_snowflake(message_id, "message id"),
         {:ok, options} <- thread_options(params) do
      case Nostrum.Api.Thread.create_with_message(channel_id, message_id, options) do
        {:ok, %Nostrum.Struct.Channel{id: id}} when not is_nil(id) ->
          {:ok, %{thread_id: to_string(id)}}

        {:ok, _unexpected} ->
          {:error, untrustworthy_response("thread")}

        {:error, error} ->
          {:error, normalize_error(error)}
      end
    end
  end

  defp message_body(%{content: content} = params)
       when is_binary(content) and content != "" do
    body = %{
      content: content,
      allowed_mentions: Map.get(params, :allowed_mentions, %{parse: []})
    }

    case Map.fetch(params, :nonce) do
      {:ok, nonce} when is_binary(nonce) or is_integer(nonce) ->
        {:ok, Map.put(body, :nonce, nonce)}

      {:ok, _invalid} ->
        {:error, invalid_request("invalid Discord message nonce")}

      :error ->
        {:ok, body}
    end
  end

  defp message_body(_params) do
    {:error, invalid_request("message content is required")}
  end

  defp thread_options(%{name: name} = params)
       when is_binary(name) and name != "" do
    duration = Map.get(params, :auto_archive_duration, 1440)

    if duration in @valid_archive_durations do
      {:ok, %{name: name, auto_archive_duration: duration}}
    else
      {:error, invalid_request("invalid Discord auto archive duration")}
    end
  end

  defp thread_options(_params) do
    {:error, invalid_request("thread name is required")}
  end

  defp decode_message_id(response_body) do
    case Jason.decode(response_body) do
      {:ok, %{"id" => id}} when is_binary(id) and id != "" ->
        {:ok, %{message_id: id}}

      {:ok, %{"id" => id}} when is_integer(id) ->
        {:ok, %{message_id: Integer.to_string(id)}}

      _invalid ->
        {:error, untrustworthy_response("message")}
    end
  end

  defp untrustworthy_response(noun) do
    %ApiError{status: 502, message: "invalid Discord #{noun} response"}
  end

  defp fetch_member_pages(guild_id, after_id, collected) do
    params = %{limit: @page_size}
    params = if after_id, do: Map.put(params, :after, after_id), else: params

    case Api.request(:get, Nostrum.Constants.guild_members(guild_id), "", params) do
      {:ok, body} -> handle_member_page(guild_id, body, collected)
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp handle_member_page(guild_id, body, collected) do
    with {:ok, page} when is_list(page) <- Jason.decode(body),
         {:ok, members} <- normalize_members(page) do
      all_members = [members | collected]

      if length(page) < @page_size do
        {:ok, all_members |> Enum.reverse() |> List.flatten()}
      else
        after_id = members |> List.last() |> Map.fetch!(:user_id)
        fetch_member_pages(guild_id, after_id, all_members)
      end
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, %ApiError{status: 502, message: "invalid Discord response", details: error}}

      {:error, reason} ->
        {:error, %ApiError{status: 502, message: "invalid Discord member", details: reason}}
    end
  end

  defp normalize_members(page) do
    {:ok, Enum.map(page, &GuildMember.from_discord/1)}
  rescue
    error -> {:error, error}
  end

  defp normalize_error({:retry_after, millis}) do
    %ApiError{
      status: 429,
      message: "Discord rate limited",
      details: %{retry_after: millis}
    }
  end

  defp normalize_error({:connection_died, reason}) do
    %ApiError{
      status: 0,
      message: "Discord connection failed",
      details: {:connection_died, reason}
    }
  end

  defp normalize_error(%NostrumApiError{status_code: status, response: response}) do
    %ApiError{
      status: status,
      code: response_value(response, :code),
      message: response_value(response, :message),
      details: response
    }
  end

  defp normalize_error(error) do
    %ApiError{status: 0, message: "Discord request failed", details: error}
  end

  defp cast_snowflake(value, label) do
    case Nostrum.Snowflake.cast(value) do
      {:ok, snowflake} when is_integer(snowflake) -> {:ok, snowflake}
      _invalid -> {:error, invalid_request("invalid Discord #{label}")}
    end
  end

  defp validate_audit_reason(reason) when is_binary(reason) do
    if String.contains?(reason, ["\r", "\n"]) do
      {:error, invalid_request("Discord audit reason cannot contain line breaks")}
    else
      :ok
    end
  end

  defp validate_audit_reason(_reason) do
    {:error, invalid_request("Discord audit reason must be a string")}
  end

  defp invalid_request(message), do: %ApiError{status: 400, message: message}

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp response_value(_response, _key), do: nil
end
