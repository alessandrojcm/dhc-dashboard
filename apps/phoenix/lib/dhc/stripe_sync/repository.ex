defmodule Dhc.StripeSync.Repository do
  @moduledoc """
  Repository module for Stripe Membership sync persistence.

  This module owns the Ecto queries that read stale Membership targets, cache
  Stripe Settings, and apply Membership status changes. `Dhc.StripeSync` keeps
  the orchestration and Stripe API implementation; this repository keeps data
  locality for the Postgres implementation.
  """

  import Ecto.Query

  alias Dhc.Repo

  @monthly_price_setting_key "stripe_monthly_price_id"

  @doc """
  Returns Stripe customer IDs for Members whose payment data is stale.
  """
  @spec get_stale_customer_ids(DateTime.t()) :: [String.t()]
  def get_stale_customer_ids(stale_before) do
    query =
      from up in "user_profiles",
        join: mp in "member_profiles",
        on: mp.user_profile_id == up.id,
        where: not is_nil(up.customer_id) and up.customer_id != "",
        where: is_nil(mp.last_payment_date) or mp.last_payment_date < ^stale_before,
        select: up.customer_id

    Repo.all(query)
  end

  @doc """
  Fetches the cached Stripe Membership price setting.
  """
  @spec fetch_cached_price_id() :: %{value: String.t(), updated_at: DateTime.t() | nil} | nil
  def fetch_cached_price_id do
    query =
      from s in "settings",
        where: s.key == ^@monthly_price_setting_key,
        select: %{value: s.value, updated_at: s.updated_at}

    Repo.one(query)
  end

  @doc """
  Upserts the cached Stripe Membership price setting.
  """
  @spec upsert_price_id_cache(String.t()) :: :ok
  def upsert_price_id_cache(price_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from s in "settings",
        where: s.key == @monthly_price_setting_key,
        select: s.id

    case Repo.one(query) do
      nil ->
        Repo.insert_all("settings", [
          [
            key: @monthly_price_setting_key,
            value: price_id,
            type: "text",
            created_at: now,
            updated_at: now
          ]
        ])

      _ ->
        Repo.update_all(
          from(s in "settings", where: s.key == ^@monthly_price_setting_key),
          set: [value: price_id, updated_at: now]
        )
    end

    :ok
  end

  @doc """
  Marks all profiles for the Stripe customer inactive.
  """
  @spec mark_customer_inactive(String.t()) :: :ok
  def mark_customer_inactive(customer_id) do
    from(up in "user_profiles", where: up.customer_id == ^customer_id)
    |> Repo.update_all(set: [is_active: false])

    :ok
  end

  @doc """
  Marks all Member profiles for the Stripe customer paused until the resume date.
  """
  @spec mark_customer_paused(String.t(), DateTime.t() | nil) :: :ok
  def mark_customer_paused(customer_id, resume_date) do
    customer_id
    |> user_profile_ids_for_customer()
    |> update_member_profiles(set: [subscription_paused_until: resume_date])

    :ok
  end

  @doc """
  Marks all profiles for the Stripe customer active and updates Membership dates.
  """
  @spec mark_customer_active(String.t(), DateTime.t() | nil, DateTime.t() | nil) :: :ok
  def mark_customer_active(customer_id, last_payment_date, ended_at) do
    customer_id
    |> user_profile_ids_for_customer()
    |> update_member_profiles(
      set: [
        subscription_paused_until: nil,
        last_payment_date: last_payment_date,
        membership_end_date: ended_at
      ]
    )

    from(up in "user_profiles", where: up.customer_id == ^customer_id)
    |> Repo.update_all(set: [is_active: true])

    :ok
  end

  defp user_profile_ids_for_customer(customer_id) do
    from(up in "user_profiles",
      where: up.customer_id == ^customer_id,
      select: up.id
    )
    |> Repo.all()
  end

  defp update_member_profiles([], _updates), do: :ok

  defp update_member_profiles(user_profile_ids, updates) do
    from(mp in "member_profiles",
      where: mp.user_profile_id in ^user_profile_ids
    )
    |> Repo.update_all(updates)

    :ok
  end
end
