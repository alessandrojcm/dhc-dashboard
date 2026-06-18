defmodule Dhc.Members do
  @moduledoc """
  Members context functions used by Phoenix API controllers.

  This is the context shell introduced by the Members read migration
  (issue #123). Later slices (member list, analytics) extend this module.
  """

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @insurance_form_link_key "hema_insurance_form_link"
  # Mirrors `member_management_view.age` (`EXTRACT(year FROM AGE(date_of_birth))`)
  # so analytics match the prior client-side aggregates exactly.
  @age_years_sql "EXTRACT(year FROM AGE(?))::int"

  @doc """
  Returns the member insurance form link.

  Reads the `hema_insurance_form_link` settings row and exposes it as a
  domain-shaped value, not a generic settings proxy. A missing row or an
  empty/whitespace-only value is reported as `nil` so callers can render
  "not configured" without knowing the storage shape.

  RBAC is enforced at the controller layer (any authenticated user), mirroring
  the `settings` SELECT RLS policy (`USING (true)` for authenticated).
  """
  @spec insurance_form() :: %{link: String.t() | nil}
  def insurance_form do
    %{link: insurance_form_link()}
  end

  @doc """
  Returns domain-shaped members analytics for the dashboard.

  Computed server-side over active members — `member_profiles` joined to
  `user_profiles` where `is_active = true` — replacing the five browser-side
  PostgREST aggregates over `member_management_view`. The `preferred_weapon[]`
  array is unnested and counted in SQL so the browser no longer downloads
  every active member's weapon array to count it in JavaScript.

  - `total_count` counts every active member (including those without a known
    date of birth).
  - `average_age` averages ages of active members with a known date of birth,
    coerced to `0.0` when none have one.
  - `gender_distribution` and `age_distribution` exclude members whose
    `gender`/`date_of_birth` is `nil` (no "Unknown"/null bucket).
  - `weapon_distribution` returns raw enum strings; the UI prettifies them.

  RBAC is enforced at the controller layer (broad committee roles), mirroring
  the `user_profiles` SELECT RLS policy.
  """
  @spec analytics() :: %{
          total_count: non_neg_integer(),
          average_age: number(),
          gender_distribution: [%{gender: String.t(), value: non_neg_integer()}],
          age_distribution: [%{age: non_neg_integer(), value: non_neg_integer()}],
          weapon_distribution: [%{weapon: String.t(), value: non_neg_integer()}]
        }
  def analytics do
    %{
      total_count: total_count(),
      average_age: average_age(),
      gender_distribution: gender_distribution(),
      age_distribution: age_distribution(),
      weapon_distribution: weapon_distribution()
    }
  end

  @spec insurance_form_link() :: String.t() | nil
  defp insurance_form_link do
    from(s in "settings",
      where: field(s, :key) == ^@insurance_form_link_key,
      select: field(s, :value)
    )
    |> Repo.one()
    |> normalize_link()
  end

  defp normalize_link(nil), do: nil

  defp normalize_link(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── Analytics ────────────────────────────────────────────────────────

  defp total_count do
    active_members_base()
    |> select([p, _m], count(p.id, :distinct))
    |> Repo.one()
  end

  defp average_age do
    # `avg/4` ignores NULL ages (members without a date_of_birth); coalesce
    # guards the empty set so callers get 0.0 instead of nil.
    active_members_base()
    |> select(
      [p, _m],
      type(coalesce(avg(fragment(@age_years_sql, p.date_of_birth)), 0.0), :float)
    )
    |> Repo.one()
  end

  defp gender_distribution do
    active_members_base()
    |> where([p, _m], not is_nil(p.gender))
    |> group_by([p, _m], p.gender)
    |> order_by([p, _m], asc: p.gender)
    |> select([p, _m], %{gender: p.gender, value: count(p.id)})
    |> Repo.all()
  end

  defp age_distribution do
    active_members_base()
    |> where([p, _m], not is_nil(p.date_of_birth))
    |> group_by([p, _m], fragment(@age_years_sql, p.date_of_birth))
    |> order_by([p, _m], asc: fragment(@age_years_sql, p.date_of_birth))
    |> select([p, _m], %{
      age: fragment(@age_years_sql, p.date_of_birth),
      value: count()
    })
    |> Repo.all()
  end

  defp weapon_distribution do
    # Unnest the `preferred_weapon[]` array in SQL and count per weapon so the
    # browser no longer downloads every active member's weapon array. Members
    # with an empty array contribute no rows (INNER LATERAL drops them —
    # correct, they own no weapon).
    #
    # The fragment is a `SELECT weapon FROM unnest(?) AS t(weapon)` subquery so
    # the unnested value gets a real column name Ecto can address as `w.weapon`
    # (Ecto rejects selecting the whole fragment binding `w`). `inner_lateral`
    # lets the subquery reference the correlated `m.preferred_weapon` column.
    # Raw enum strings are returned; the UI prettifies them for display.
    active_members_base()
    |> join(
      :inner_lateral,
      [p, m],
      w in fragment("SELECT weapon FROM unnest(?) AS t(weapon)", m.preferred_weapon), on: true)
    |> group_by([..., w], w.weapon)
    |> order_by([..., w], asc: w.weapon)
    |> select([..., w], %{weapon: w.weapon, value: count()})
    |> Repo.all()
  end

  defp active_members_base do
    from p in UserProfile,
      join: m in "member_profiles",
      on: field(m, :user_profile_id) == p.id,
      where: p.is_active == true
  end
end
