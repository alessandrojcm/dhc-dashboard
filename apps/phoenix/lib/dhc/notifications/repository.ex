defmodule Dhc.Notifications.Repository do
  @moduledoc """
  Repository module for Notification persistence.
  """

  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @doc """
  Creates a Notification for a user.
  """
  @spec create(String.t(), String.t()) :: :ok | {:error, term()}
  def create(user_id, body) when is_binary(user_id) and is_binary(body) do
    notification = %Notification{
      user_id: user_id,
      body: body,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case Repo.insert(notification) do
      {:ok, _notification} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Ecto.ConstraintError, Postgrex.Error] -> {:error, error}
  end
end
