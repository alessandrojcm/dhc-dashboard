defmodule Dhc.BeginnersWorkshops.Commands.IntakeHistory do
  @moduledoc """
  The Intake history (`IntakeEvent`): one row per command that acted on an
  Intake — command, actor (a Principal, or an Intake Reply for a Reply
  Action, ALE-411), time, optional note, a correction's target — in
  the command's transaction (ALE-386, ALE-405), and the note bound every
  history note shares.

    * `record_intake_event/5` — `Commands.IntakeCommands` (every console
      Intake command), `Commands.Schedule` (`cancel_workshop`) and
      `Commands.Attendance` (door check-in and undo);
    * `command_note/1` — `Commands.IntakeCommands`;
    * `bounded_note/1` — `command_note/1` and `Commands.Schedule`
      (`cancel_workshop`'s reason).

  Reach lets only `Commands` and `Commands.*` call this module.
  """

  import Dhc.BeginnersWorkshops.Commands.Protocol, only: [persist: 1]
  import Dhc.BeginnersWorkshops.Commands.Input, only: [fetch_attr: 2]

  alias Dhc.BeginnersWorkshops.{Clock, Intake, IntakeEvent}

  @doc false
  @spec record_intake_event(Intake.t(), atom(), binary(), map(), Clock.reading()) ::
          {:ok, IntakeEvent.t()} | {:error, term()}
  def record_intake_event(intake, command, event_id, context, reading) do
    %{actor: actor, note: note, options: options} = context

    %{
      id: event_id,
      intake_id: intake.id,
      command: Atom.to_string(command),
      actor_principal_id: actor,
      note: note,
      correction: Map.get(options, :to),
      intake_reply_id: Map.get(context, :intake_reply_id),
      occurred_at: reading.now
    }
    |> IntakeEvent.changeset()
    |> persist()
  end

  @doc false
  # A command's optional note (`note`): trimmed, blank is none.
  @spec command_note(map()) :: {:ok, String.t() | nil} | {:error, :invalid_note}
  def command_note(attrs) do
    case fetch_attr(attrs, :note) do
      nil ->
        {:ok, nil}

      note when is_binary(note) ->
        note |> String.trim() |> bounded_note()

      _other ->
        {:error, :invalid_note}
    end
  end

  @doc false
  @spec bounded_note(String.t()) :: {:ok, String.t() | nil} | {:error, :invalid_note}
  def bounded_note(""), do: {:ok, nil}

  def bounded_note(note) do
    if String.length(note) <= IntakeEvent.note_max(),
      do: {:ok, note},
      else: {:error, :invalid_note}
  end
end
