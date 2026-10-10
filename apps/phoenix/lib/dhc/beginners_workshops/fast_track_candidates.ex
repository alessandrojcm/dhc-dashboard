defmodule Dhc.BeginnersWorkshops.FastTrackCandidates do
  @moduledoc """
  The Fast-track dialog's search (ALE-384): `waiting` people and people
  `removed` within the 3-month retention window (`Dhc.Waitlist.restorable?/2`),
  skipping anyone with an open Intake — exactly the people `fast_track` would
  place. Lock-free and actor-free: the route's capability gate is its
  authorization, and the boundary decides again under the lock.

  Only people with a Waitlist profile and an email are listed (the Contact
  email is addressed by first name). Matches the search text against first
  name, last name and email; oldest priority first, at most `@limit` rows.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, Intake, WorkshopPolicy}
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  @limit 20

  # A calendar-month window is not a fixed number of days, so the query
  # over-selects by a few days and `Waitlist.restorable?/2` decides.
  @retention_months 3
  @retention_slack_days 4

  @type t :: %{
          waitlist_id: binary(),
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          email: String.t(),
          status: String.t(),
          removed_at: DateTime.t() | nil,
          minor: boolean()
        }

  @doc "The candidates for `workshop_id` matching `search`, judged at the clock's reading."
  @spec search(binary(), String.t() | nil, Clock.t()) :: {:ok, [t()]} | {:error, :not_found}
  def search(workshop_id, search, %Clock{} = clock) do
    with {:ok, id} <- Ecto.UUID.cast(workshop_id),
         %BeginnersWorkshop{} = workshop <- Repo.get(BeginnersWorkshop, id) do
      now = Clock.read(clock).now

      rows =
        now
        |> candidates()
        |> matching(search)
        |> Repo.all()
        |> Enum.filter(&(&1.status == "waiting" or Waitlist.restorable?(&1.removed_at, now)))
        |> Enum.take(@limit)
        |> Enum.map(fn row ->
          row
          |> Map.delete(:date_of_birth)
          |> Map.put(:minor, WorkshopPolicy.minor?(row.date_of_birth, workshop.date))
        end)

      {:ok, rows}
    else
      _ -> {:error, :not_found}
    end
  end

  defp candidates(now) do
    open = Intake.open_states()

    removed_since =
      now
      |> DateTime.shift(month: -@retention_months)
      |> DateTime.add(-@retention_slack_days, :day)

    from(e in WaitlistEntry,
      as: :entry,
      join: p in UserProfile,
      on: p.waitlist_id == e.id,
      as: :profile,
      where: not is_nil(e.email),
      where:
        e.status == "waiting" or
          (e.status == "removed" and e.removed_at >= ^removed_since),
      where:
        not exists(
          from(i in Intake,
            where: i.waitlist_id == parent_as(:entry).id and i.state in ^open,
            select: 1
          )
        ),
      order_by: [asc: e.initial_registration_date, asc: e.id],
      # Over-fetch so the Elixir retention filter can still fill the page.
      limit: ^(@limit * 2),
      select: %{
        waitlist_id: e.id,
        first_name: p.first_name,
        last_name: p.last_name,
        email: e.email,
        status: e.status,
        removed_at: e.removed_at,
        date_of_birth: p.date_of_birth
      }
    )
  end

  defp matching(query, search) when is_binary(search) do
    case String.trim(search) do
      "" ->
        query

      text ->
        pattern = "%" <> escape_like(text) <> "%"

        where(
          query,
          [entry: e, profile: p],
          ilike(p.first_name, ^pattern) or ilike(p.last_name, ^pattern) or
            ilike(e.email, ^pattern) or
            ilike(fragment("concat_ws(' ', ?, ?)", p.first_name, p.last_name), ^pattern)
        )
    end
  end

  defp matching(query, _search), do: query

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")
end
