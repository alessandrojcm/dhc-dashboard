defmodule Dhc.BeginnersWorkshops.StaffCandidates do
  @moduledoc """
  Who the Staff dialog may pick (ALE-379): every active Member, each marked
  whether they may be assigned as coach (`beginners.workshops.lead`). The
  same capabilities `set_staff` checks, read without a lock, so the pickers
  can be stale but never offer a different rule. Sorted by name.
  """

  import Ecto.Query

  alias Dhc.Auth.Capabilities
  alias Dhc.BeginnersWorkshops.WorkshopFacts
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @type t :: %{principal_id: binary(), name: String.t(), coach: boolean()}

  @doc "Every active Member who may be assigned, coaches marked."
  @spec list() :: [t()]
  def list do
    members = Capabilities.principal_ids_with(:"beginners.workshops.assigned.read")
    coaches = MapSet.new(Capabilities.principal_ids_with(:"beginners.workshops.lead"))

    from(p in UserProfile,
      where: p.principal_id in ^members,
      order_by: [asc: p.first_name, asc: p.last_name, asc: p.principal_id],
      select: {p.principal_id, p.first_name, p.last_name}
    )
    |> Repo.all()
    |> Enum.map(fn {id, first, last} ->
      %{
        principal_id: id,
        name: WorkshopFacts.display_name(first, last),
        coach: MapSet.member?(coaches, id)
      }
    end)
  end
end
