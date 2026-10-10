defmodule Dhc.BeginnersWorkshops.BatchProposal do
  @moduledoc """
  The live Batch proposal (ALE-380): `waiting` people in
  `initial_registration_date` order, skipping anyone with an open Intake.

  The console's Next Batch preview (lock-free) and the boundary's
  `send_due_batch` (under the Beginners' Workshop lock, then locking the
  proposed Waitlist entries and checking them again) read it through this
  one module, so the preview is exactly what would be sent at that moment.

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

  @doc "The first `size` eligible people, in priority order."
  @spec people(non_neg_integer()) :: [person()]
  def people(size) when is_integer(size) and size <= 0, do: []

  def people(size) when is_integer(size) do
    eligible()
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

  @doc "The ids among `waitlist_ids` that are still eligible (re-checked under the lock)."
  @spec still_eligible([binary()]) :: [binary()]
  def still_eligible([]), do: []

  def still_eligible(waitlist_ids) do
    eligible()
    |> where([e], e.id in ^waitlist_ids)
    |> select([e], e.id)
    |> Repo.all()
  end

  @doc "Whether anyone at all is eligible."
  @spec anyone_waiting?() :: boolean()
  def anyone_waiting?, do: Repo.exists?(eligible())

  defp eligible do
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
      order_by: [asc: e.initial_registration_date, asc: e.id]
    )
  end
end
