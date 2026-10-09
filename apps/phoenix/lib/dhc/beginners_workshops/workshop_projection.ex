defmodule Dhc.BeginnersWorkshops.WorkshopProjection do
  @moduledoc """
  The one closed view of a Beginners' Workshop row. The Workshops list and
  every workshop command return it, so a command result and a list row cannot
  disagree. Civil values are Europe/Dublin; the Payment Cutoff is given both
  as its instant and as its Dublin date and time.
  """

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, WorkshopFacts, WorkshopPolicy}
  alias Dhc.ClubCalendar

  @type t :: %{
          id: binary(),
          status: String.t(),
          venue: String.t(),
          date: Date.t(),
          start_time: Time.t(),
          capacity: pos_integer(),
          fee_cents: pos_integer(),
          payment_cutoff: DateTime.t(),
          payment_cutoff_date: Date.t(),
          payment_cutoff_time: Time.t(),
          contact_from: Date.t(),
          contact_from_editable: boolean(),
          payment_window_days: pos_integer(),
          stage: WorkshopPolicy.stage(),
          seats: map(),
          alerts: [WorkshopPolicy.alert()],
          staff: WorkshopFacts.staff()
        }

  @doc "Projects a workshop with its facts at a clock reading."
  @spec view(BeginnersWorkshop.t(), map(), map()) :: t()
  def view(%BeginnersWorkshop{} = workshop, facts, reading) do
    %{
      id: workshop.id,
      status: workshop.status,
      venue: workshop.venue,
      date: workshop.date,
      start_time: workshop.start_time,
      capacity: workshop.capacity,
      fee_cents: workshop.fee_cents,
      payment_cutoff: workshop.payment_cutoff,
      payment_cutoff_date: ClubCalendar.on_date(workshop.payment_cutoff),
      payment_cutoff_time:
        workshop.payment_cutoff |> ClubCalendar.time_on() |> Time.truncate(:second),
      contact_from: workshop.contact_from,
      contact_from_editable: WorkshopPolicy.contact_from_editable?(facts),
      payment_window_days: workshop.payment_window_days,
      stage: WorkshopPolicy.stage(workshop, facts, reading),
      seats: WorkshopPolicy.seats(workshop, facts),
      alerts: WorkshopPolicy.alerts(workshop, facts),
      staff: facts.staff
    }
  end
end
