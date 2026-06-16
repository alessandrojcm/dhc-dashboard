defmodule Dhc.Waitlist do
  @moduledoc """
  Waitlist context functions used by Phoenix API controllers.
  """

  import Ecto.Query

  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Repo

  @waitlist_open_key "waitlist_open"
  @age_years_sql "EXTRACT(YEAR FROM AGE(CURRENT_DATE, ?))::int"

  @doc """
  Returns the public waitlist status.

  Missing or malformed settings are treated as closed so the public endpoint
  always returns a safe domain-shaped status instead of exposing settings rows.
  """
  @spec status() :: %{is_open: boolean()}
  def status do
    %{is_open: open?()}
  end

  @doc """
  Returns domain-shaped waitlist analytics for the dashboard.

  The queries intentionally read the `waitlist` and `user_profiles` storage
  tables directly inside Phoenix, rather than exposing `waitlist_management_view`
  or `user_profiles` as API resources.
  """
  @spec analytics() :: %{
          total_count: non_neg_integer(),
          average_age: number(),
          gender_distribution: [%{gender: String.t(), value: non_neg_integer()}],
          age_distribution: [%{age: non_neg_integer(), value: non_neg_integer()}]
        }
  def analytics do
    %{
      total_count: total_count(),
      average_age: average_age(),
      gender_distribution: gender_distribution(),
      age_distribution: age_distribution()
    }
  end

  @spec open?() :: boolean()
  def open? do
    from(s in "settings",
      where: field(s, :key) == ^@waitlist_open_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> case do
      "true" -> true
      _ -> false
    end
  end

  defp total_count do
    base_analytics_query()
    |> select([w, _p], count(w.id, :distinct))
    |> Repo.one()
  end

  defp average_age do
    base_analytics_query()
    |> select(
      [_w, p],
      type(coalesce(avg(fragment(@age_years_sql, p.date_of_birth)), 0.0), :float)
    )
    |> Repo.one()
  end

  defp gender_distribution do
    base_analytics_query()
    |> where([_w, p], not is_nil(p.gender))
    |> group_by([_w, p], p.gender)
    |> order_by([_w, p], asc: p.gender)
    |> select([_w, p], %{gender: p.gender, value: count(p.id)})
    |> Repo.all()
  end

  defp age_distribution do
    base_analytics_query()
    |> group_by(
      [_w, p],
      fragment(@age_years_sql, p.date_of_birth)
    )
    |> order_by(
      [_w, p],
      asc: fragment(@age_years_sql, p.date_of_birth)
    )
    |> select([_w, p], %{
      age: fragment(@age_years_sql, p.date_of_birth),
      value: count()
    })
    |> Repo.all()
  end

  defp base_analytics_query do
    from w in WaitlistEntry,
      join: p in UserProfile,
      on: p.waitlist_id == w.id,
      where:
        w.status != "joined" and p.is_active == false and is_nil(p.supabase_user_id) and
          not is_nil(p.date_of_birth)
  end
end
