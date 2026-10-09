defmodule Dhc.BeginnersWorkshops.Invitable do
  @moduledoc """
  The cross-workshop Invitable view (ALE-392): everyone whose Waitlist
  standing is `attended`, with the attended Intake an Invitation is sent
  from, that workshop's date and whether its Follow-up has gone out. A
  lock-free, actor-free read model; the route's `members.invite` gate is
  its authorization, and `invite` re-decides everything under the lock.

  A person leaves the list once invited (standing `invited`) and comes back
  if that Invitation is deleted (standing `attended` again). A person with
  more than one attended Intake is listed once, from the latest workshop.
  Oldest workshop first, then by name.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Intake, IntakeEmailLog, WorkshopPolicy}
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @type follow_up :: %{status: :sent | :scheduled, at: DateTime.t()}

  @type t :: %{
          intake_id: binary(),
          workshop_id: binary(),
          workshop_date: Date.t(),
          waitlist_id: binary(),
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          email: String.t(),
          follow_up: follow_up()
        }

  @doc "Everyone Invitable now."
  @spec list() :: [t()]
  def list do
    latest =
      from(i in Intake,
        join: w in BeginnersWorkshop,
        on: w.id == i.workshop_id,
        where: i.state == "attended" and w.status == "finalised" and not is_nil(i.waitlist_id),
        distinct: i.waitlist_id,
        order_by: [asc: i.waitlist_id, desc: w.date, desc: i.id],
        select: %{intake_id: i.id, waitlist_id: i.waitlist_id}
      )

    from(l in subquery(latest),
      join: i in Intake,
      on: i.id == l.intake_id,
      join: w in BeginnersWorkshop,
      on: w.id == i.workshop_id,
      join: e in WaitlistEntry,
      on: e.id == l.waitlist_id,
      left_join: p in UserProfile,
      on: p.waitlist_id == e.id,
      left_join: f in IntakeEmailLog,
      on: f.intake_id == i.id and f.occasion == "follow_up",
      where: e.status == "attended",
      order_by: [asc: w.date, asc: p.first_name, asc: p.last_name, asc: i.id],
      select: %{
        intake_id: i.id,
        workshop: w,
        waitlist_id: e.id,
        email: e.email,
        first_name: p.first_name,
        last_name: p.last_name,
        follow_up_sent_at: f.queued_at
      }
    )
    |> Repo.all()
    |> Enum.map(&row/1)
  end

  defp row(%{workshop: workshop} = row) do
    %{
      intake_id: row.intake_id,
      workshop_id: workshop.id,
      workshop_date: workshop.date,
      waitlist_id: row.waitlist_id,
      first_name: row.first_name,
      last_name: row.last_name,
      email: row.email,
      follow_up: follow_up(row.follow_up_sent_at, workshop)
    }
  end

  defp follow_up(nil, workshop),
    do: %{status: :scheduled, at: WorkshopPolicy.follow_up_at(workshop)}

  defp follow_up(%DateTime{} = sent_at, _workshop), do: %{status: :sent, at: sent_at}
end
