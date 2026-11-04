defmodule Dhc.BeginnersWorkshops.BatchProposal do
  @moduledoc """
  The live Batch proposal (ALE-380): `waiting` people in
  `initial_registration_date` order, skipping anyone with an open Intake
  anywhere or any prior Intake for this workshop, whatever its state.

  A closed Intake excludes only this workshop, even after a reschedule;
  the person remains eligible for a different workshop while waiting.
  Fast-track deliberately skips only open Intakes: a coordinator may place
  someone who called back after declining the same workshop.

  The console's Next Batch preview (lock-free) and the boundary's
  `send_due_batch` (under the Beginners' Workshop lock, then locking the
  proposed Waitlist entries and reading the proposal again, which must be
  exactly those people) read it through this one module, so the preview is
  exactly what would be sent at that moment.

  Only people with a Waitlist profile are proposed: the contact email is
  addressed by first name. Each person says whether they hold a `held`
  Carried Fee (`confirms`, ALE-388): they will be asked to confirm, not pay.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{CarriedFee, Intake}
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @type person :: %{
          waitlist_id: binary(),
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          date_of_birth: Date.t() | nil,
          queue_date: DateTime.t(),
          confirms: boolean()
        }

  @doc "The first `size` eligible people for `workshop_id`, in priority order."
  @spec people(binary(), non_neg_integer()) :: [person()]
  def people(_workshop_id, size) when is_integer(size) and size <= 0, do: []

  def people(workshop_id, size) when is_integer(size) do
    eligible(workshop_id)
    |> limit(^size)
    |> select([e, p], %{
      waitlist_id: e.id,
      first_name: p.first_name,
      last_name: p.last_name,
      date_of_birth: p.date_of_birth,
      queue_date: e.initial_registration_date,
      confirms:
        exists(
          from(f in CarriedFee,
            where: f.waitlist_id == parent_as(:entry).id and f.status == "held",
            select: 1
          )
        )
    })
    |> Repo.all()
  end

  defp eligible(workshop_id) do
    open = Intake.open_states()

    from(e in WaitlistEntry,
      as: :entry,
      join: p in UserProfile,
      on: p.waitlist_id == e.id,
      where: e.status == "waiting" and not is_nil(e.email),
      where:
        not exists(
          from(i in Intake,
            where: i.waitlist_id == parent_as(:entry).id and i.state in ^open,
            select: 1
          )
        ),
      where:
        not exists(
          from(i in Intake,
            where: i.waitlist_id == parent_as(:entry).id and i.workshop_id == ^workshop_id,
            select: 1
          )
        ),
      order_by: [asc: e.initial_registration_date, asc: e.id]
    )
  end
end
