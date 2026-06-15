defmodule Dhc.UserProfiles.Repository do
  @moduledoc """
  Repository module for User Profile persistence.
  """

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @doc """
  Creates or updates the inactive User Profile created during Invitation processing.

  When `waitlist_id` is nil, any existing waitlist link is preserved.
  """
  @spec upsert_invited_profile(map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, UserProfile.t()} | {:error, term()}
  def upsert_invited_profile(invite_data, user_id, customer_id, waitlist_id) do
    profile = %UserProfile{
      supabase_user_id: user_id,
      first_name: invite_data["firstName"],
      last_name: invite_data["lastName"],
      date_of_birth: date(invite_data["dateOfBirth"]),
      phone_number: invite_data["phoneNumber"],
      customer_id: customer_id,
      is_active: false,
      waitlist_id: waitlist_id
    }

    on_conflict =
      [
        first_name: profile.first_name,
        last_name: profile.last_name,
        date_of_birth: profile.date_of_birth,
        phone_number: profile.phone_number,
        customer_id: profile.customer_id,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
      |> maybe_set_waitlist_id(waitlist_id)

    Repo.insert(profile,
      conflict_target: [:supabase_user_id],
      on_conflict: [set: on_conflict],
      returning: true
    )
  end

  defp maybe_set_waitlist_id(updates, nil), do: updates

  defp maybe_set_waitlist_id(updates, waitlist_id),
    do: Keyword.put(updates, :waitlist_id, waitlist_id)

  defp date(%Date{} = date), do: date
  defp date(%DateTime{} = date_time), do: DateTime.to_date(date_time)

  defp date(value) when is_binary(value) do
    value
    |> String.split("T")
    |> List.first()
    |> Date.from_iso8601!()
  end
end
