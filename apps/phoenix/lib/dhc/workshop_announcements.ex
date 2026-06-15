defmodule Dhc.WorkshopAnnouncements do
  @moduledoc """
  Context module for workshop announcement processing.

  Provides database queries and message formatting for the
  `Dhc.WorkshopAnnouncements.Worker`. This separation keeps the worker
  focused on job orchestration while the context handles domain logic.
  """

  import Ecto.Query

  require Logger

  alias Dhc.Repo

  @type workshop :: %{
          id: String.t(),
          title: String.t(),
          location: String.t(),
          start_date: DateTime.t(),
          status: String.t(),
          announce_discord: boolean(),
          announce_email: boolean()
        }

  @type active_user :: %{
          user_id: String.t(),
          email: String.t(),
          first_name: String.t(),
          last_name: String.t()
        }

  @doc """
  Fetches a workshop by its UUID.

  Returns `{:ok, workshop}` if found, `{:error, :not_found}` otherwise.
  """
  @spec fetch_workshop(String.t()) :: {:ok, workshop()} | {:error, :not_found}
  def fetch_workshop(workshop_id) do
    query =
      from ca in "club_activities",
        where: ca.id == ^Ecto.UUID.dump!(workshop_id),
        select: %{
          id: ca.id,
          title: ca.title,
          location: ca.location,
          start_date: ca.start_date,
          status: ca.status,
          announce_discord: ca.announce_discord,
          announce_email: ca.announce_email
        }

    case Repo.one(query) do
      nil ->
        Logger.error("[workshop-announcements] Workshop not found",
          workshop_id: workshop_id
        )

        {:error, :not_found}

      workshop ->
        {:ok, workshop}
    end
  end

  @doc """
  Lists all active users with email addresses.

  Returns a list of maps with `user_id`, `email`, `first_name`, and `last_name`.
  """
  @spec list_active_users() :: [active_user()]
  def list_active_users do
    query =
      from up in "user_profiles",
        join: au in "users",
        on: up.supabase_user_id == au.id,
        where: up.is_active == true and not is_nil(au.email),
        select: %{
          user_id: up.supabase_user_id,
          email: au.email,
          first_name: up.first_name,
          last_name: up.last_name
        }

    Repo.all(query)
  end

  @doc """
  Formats a Discord message for a single workshop announcement.

  Generates a human-readable message with emoji headers based on the
  announcement type and workshop status.
  """
  @spec format_discord_message(workshop(), String.t()) :: String.t()
  def format_discord_message(workshop, announcement_type) do
    formatted_date = format_date(workshop.start_date)

    case announcement_type do
      "created" ->
        case workshop.status do
          "planned" ->
            "📅 **New Workshop Being Planned:**\n• #{workshop.title} on #{formatted_date} at #{workshop.location}\nHead to \"My Workshops\" to express your interest!"

          "published" ->
            "🎯 **Registration Now Open:**\n• #{workshop.title} on #{formatted_date} at #{workshop.location}\nHead to \"My Workshops\" to register!"

          _ ->
            "🗡️ **Workshop Update:**\n• #{workshop.title} on #{formatted_date} at #{workshop.location}"
        end

      "status_changed" ->
        case workshop.status do
          "published" ->
            "🎯 **Registration Now Open:**\n• #{workshop.title} on #{formatted_date} at #{workshop.location}\nHead to \"My Workshops\" to register!"

          "cancelled" ->
            "❌ **Cancelled Workshop:**\n• #{workshop.title} scheduled for #{formatted_date} has been cancelled"

          _ ->
            "🗡️ **Workshop Status Update:**\n• #{workshop.title} on #{formatted_date} at #{workshop.location}"
        end

      "time_changed" ->
        "⏰ **Schedule Change:**\n• #{workshop.title} is now scheduled for #{formatted_date} at #{workshop.location}"

      "location_changed" ->
        "📍 **Location Change:**\n• #{workshop.title} on #{formatted_date} will now be held at #{workshop.location}"
    end
  end

  @doc """
  Formats an email message body for a single workshop announcement.

  Produces a plain-text message suitable for use as a Loops email template
  data variable.
  """
  @spec format_email_message(workshop(), String.t()) :: String.t()
  def format_email_message(workshop, announcement_type) do
    formatted_date = format_date(workshop.start_date)

    case announcement_type do
      "created" ->
        case workshop.status do
          "planned" ->
            "New Workshop Being Planned: #{workshop.title} on #{formatted_date} at #{workshop.location}. Head to \"My Workshops\" to express your interest!"

          "published" ->
            "Registration Now Open: #{workshop.title} on #{formatted_date} at #{workshop.location}. Head to \"My Workshops\" to register!"

          _ ->
            "Workshop Update: #{workshop.title} on #{formatted_date} at #{workshop.location}"
        end

      "status_changed" ->
        case workshop.status do
          "published" ->
            "Registration Now Open: #{workshop.title} on #{formatted_date} at #{workshop.location}. Head to \"My Workshops\" to register!"

          "cancelled" ->
            "Cancelled Workshop: #{workshop.title} scheduled for #{formatted_date} has been cancelled."

          _ ->
            "Workshop Status Update: #{workshop.title} on #{formatted_date} at #{workshop.location}"
        end

      "time_changed" ->
        "Schedule Change: #{workshop.title} is now scheduled for #{formatted_date} at #{workshop.location}."

      "location_changed" ->
        "Location Change: #{workshop.title} on #{formatted_date} will now be held at #{workshop.location}."
    end
  end

  @doc """
  Formats a datetime for display in messages.

  Returns a human-readable date string like "January 15, 2024 at 3:00 PM".
  """
  @spec format_date(DateTime.t()) :: String.t()
  def format_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%B %d, %Y at %I:%M %p")
  end

  def format_date(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_date(dt)
      {:error, _} -> datetime
    end
  end
end
