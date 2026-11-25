defmodule Dhc.GoogleCalendar do
  @moduledoc """
  Read-only operator diagnostics for the shared Calendar connection and its
  three configured targets. Works on a running release without Mix or Repo.
  Checks never activate sending, enqueue jobs, mutate Google, or expose tokens,
  calendar contents, target IDs or provider response bodies.
  """

  alias Dhc.GoogleCalendar.Auth

  @doc "Checks credentials loaded in this process, then reads each explicit target."
  @spec check() :: %{authentication: atom(), calendars: %{atom() => atom()}}
  def check do
    case Auth.check() do
      :ok ->
        workshop = Application.get_env(:dhc, Dhc.WorkshopCalendar, [])
        training = Application.get_env(:dhc, Dhc.TrainingCalendar, [])

        %{
          authentication: :ok,
          calendars: %{
            committee:
              check_target(
                workshop[:committee_calendar_id],
                &Dhc.WorkshopCalendar.Google.check_calendar/1
              ),
            participants:
              check_target(
                workshop[:participant_calendar_id],
                &Dhc.WorkshopCalendar.Google.check_calendar/1
              ),
            training: check_target(training[:calendar_id], &Dhc.TrainingCalendar.Google.list/1)
          }
        }

      {:error, reason} ->
        %{authentication: reason, calendars: %{}}
    end
  end

  defp check_target(id, check) when is_binary(id) do
    if String.trim(id) in ["", "primary"] do
      :configuration
    else
      case check.(id) do
        :ok -> :ok
        {:ok, _contents} -> :ok
        {:error, :configuration} -> :target_inaccessible
        {:error, reason} -> reason
      end
    end
  end

  defp check_target(_id, _check), do: :configuration
end
