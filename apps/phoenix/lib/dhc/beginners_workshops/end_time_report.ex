defmodule Dhc.BeginnersWorkshops.EndTimeReport do
  @moduledoc """
  Read-only operational report of upcoming Beginners' Workshop schedules that
  cannot yet be published to a calendar because their end time is absent or
  invalid. It never infers a duration or changes a workshop.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, WorkshopPolicy}
  alias Dhc.Repo

  @type row :: %{
          id: binary(),
          date: Date.t(),
          start_time: Time.t(),
          end_time: Time.t() | nil,
          issue: :missing | :invalid
        }

  @doc "Lists scheduled workshops whose Dublin start instant is still future and whose end time is unusable."
  @spec load(Clock.t()) :: [row()]
  def load(%Clock{} = clock) do
    reading = Clock.read(clock)

    from(w in BeginnersWorkshop,
      where: w.status == "scheduled",
      order_by: [asc: w.date, asc: w.start_time, asc: w.id]
    )
    |> Repo.all()
    |> Enum.filter(&WorkshopPolicy.starts_after?(&1, reading.now))
    |> Enum.flat_map(&row/1)
  end

  defp row(%BeginnersWorkshop{end_time: nil} = workshop),
    do: [Map.put(base(workshop), :issue, :missing)]

  defp row(%BeginnersWorkshop{} = workshop),
    do:
      if(WorkshopPolicy.valid_end_time?(workshop),
        do: [],
        else: [Map.put(base(workshop), :issue, :invalid)]
      )

  defp base(workshop) do
    Map.take(workshop, [:id, :date, :start_time, :end_time])
  end
end
