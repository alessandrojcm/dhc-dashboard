defmodule Dhc.BeginnersWorkshops.Commands.CalendarLaunch do
  @moduledoc false

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [transact: 1, with_locked: 2]

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CalendarProjection,
    Clock,
    Intake,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.Commands
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.WorkshopCalendar

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run(:system, {:materialize_calendar_launch, workshop_id}, clock) do
    transact(fn ->
      with_locked(
        %{
          workshop: from(w in BeginnersWorkshop, where: w.id == ^workshop_id),
          waitlist_entry: {:all, entries_query(workshop_id)},
          intake: {:all, paid_intakes_query(workshop_id)}
        },
        fn locked -> materialize_locked(locked, Clock.read(clock).now) end
      )
    end)
  end

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  defp materialize_locked(%{workshop: nil}, _now), do: {:ok, :noop}

  defp materialize_locked(%{workshop: workshop} = locked, now) do
    source = CalendarProjection.project(workshop)

    cond do
      source.status == "cancelled" or not future?(source.start_date, now) ->
        {:ok, :noop}

      is_nil(workshop.end_time) ->
        {:error, :missing_end_time}

      not WorkshopPolicy.valid_end_time?(workshop) ->
        {:error, :invalid_schedule}

      true ->
        entries = Map.new(locked.waitlist_entry, &{&1.id, &1.email})

        with :ok <- WorkshopCalendar.record_change(:beginners_workshop, workshop.id) do
          Enum.each(locked.intake, &confirm_place(&1, entries))

          {:ok, :materialized}
        end
    end
  end

  defp confirm_place(intake, entries) do
    case Map.fetch(entries, intake.waitlist_id) do
      {:ok, email} ->
        :ok =
          WorkshopCalendar.confirm_place(
            :beginners_workshop,
            intake.workshop_id,
            intake.id,
            email
          )

      :error ->
        :ok
    end
  end

  defp entries_query(workshop_id) do
    paid_intake_ids =
      from(i in Intake,
        where:
          i.workshop_id == ^workshop_id and i.state in ["paid", "attended", "no_show"] and
            not is_nil(i.waitlist_id),
        select: i.waitlist_id
      )

    from(e in WaitlistEntry, where: e.id in subquery(paid_intake_ids))
  end

  defp paid_intakes_query(workshop_id),
    do:
      from(i in Intake,
        where:
          i.workshop_id == ^workshop_id and i.state in ["paid", "attended", "no_show"] and
            not is_nil(i.waitlist_id)
      )

  defp future?(%DateTime{} = start_date, now), do: DateTime.compare(start_date, now) == :gt
  defp future?(_start_date, _now), do: false
end
