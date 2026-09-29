defmodule Dhc.TrainingAnnouncements.Channels do
  @moduledoc """
  Independently optional deployment destinations. Missing or blank channel
  configuration blocks that kind at delivery validation, never at boot;
  there is no cross-kind fallback or caller-supplied destination.
  """

  def for_kind("roll_call"), do: configured(:discord_roll_call_channel_id)
  def for_kind("sparring"), do: configured(:discord_sparring_channel_id)
  def for_kind("holiday"), do: configured(:discord_training_announcements_channel_id)

  defp configured(key) do
    case Application.get_env(:dhc, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :unconfigured_channel}
          id -> {:ok, id}
        end

      _ ->
        {:error, :unconfigured_channel}
    end
  end
end
