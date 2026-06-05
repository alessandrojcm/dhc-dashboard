defmodule Dhc.WorkshopAnnouncementsTest do
  use ExUnit.Case, async: true

  alias Dhc.WorkshopAnnouncements

  @workshop_planned %{
    id: "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    title: "HEMA Open Session",
    location: "Dublin Fencing Club",
    start_date: ~U[2024-03-15 18:00:00Z],
    status: "planned",
    announce_discord: true,
    announce_email: true
  }

  @workshop_published %{
    id: "a1b2c3d4-5678-1234-abcd-ef0123456789",
    title: "Longsword Basics",
    location: "Dublin Sport Centre",
    start_date: ~U[2024-04-20 10:00:00Z],
    status: "published",
    announce_discord: true,
    announce_email: true
  }

  @workshop_cancelled %{
    id: "c3d4e5f6-7890-1234-abcd-ef0123456789",
    title: "Rapier Workshop",
    location: "Trinity College",
    start_date: ~U[2024-05-01 14:00:00Z],
    status: "cancelled",
    announce_discord: true,
    announce_email: true
  }

  describe "format_discord_message/2" do
    test "formats 'created' announcement for planned workshop" do
      message = WorkshopAnnouncements.format_discord_message(@workshop_planned, "created")

      assert message =~ "📅"
      assert message =~ "New Workshop Being Planned"
      assert message =~ "HEMA Open Session"
      assert message =~ "March 15, 2024"
      assert message =~ "Dublin Fencing Club"
      assert message =~ "express your interest"
    end

    test "formats 'created' announcement for published workshop" do
      message = WorkshopAnnouncements.format_discord_message(@workshop_published, "created")

      assert message =~ "🎯"
      assert message =~ "Registration Now Open"
      assert message =~ "Longsword Basics"
    end

    test "formats 'status_changed' announcement for published workshop" do
      message =
        WorkshopAnnouncements.format_discord_message(@workshop_published, "status_changed")

      assert message =~ "🎯"
      assert message =~ "Registration Now Open"
    end

    test "formats 'status_changed' announcement for cancelled workshop" do
      message =
        WorkshopAnnouncements.format_discord_message(@workshop_cancelled, "status_changed")

      assert message =~ "❌"
      assert message =~ "Cancelled Workshop"
      assert message =~ "Rapier Workshop"
      assert message =~ "cancelled"
    end

    test "formats 'time_changed' announcement" do
      message = WorkshopAnnouncements.format_discord_message(@workshop_planned, "time_changed")

      assert message =~ "⏰"
      assert message =~ "Schedule Change"
      assert message =~ "HEMA Open Session"
      assert message =~ "now scheduled for"
    end

    test "formats 'location_changed' announcement" do
      message =
        WorkshopAnnouncements.format_discord_message(@workshop_planned, "location_changed")

      assert message =~ "📍"
      assert message =~ "Location Change"
      assert message =~ "will now be held at"
      assert message =~ "Dublin Fencing Club"
    end

    test "formats 'created' with unknown status as generic update" do
      workshop = %{@workshop_planned | status: "finished"}
      message = WorkshopAnnouncements.format_discord_message(workshop, "created")

      assert message =~ "🗡️"
      assert message =~ "Workshop Update"
    end

    test "formats 'status_changed' with unknown status as generic update" do
      workshop = %{@workshop_planned | status: "planned"}
      message = WorkshopAnnouncements.format_discord_message(workshop, "status_changed")

      assert message =~ "🗡️"
      assert message =~ "Workshop Status Update"
    end
  end

  describe "format_email_message/2" do
    test "formats 'created' email for planned workshop" do
      message = WorkshopAnnouncements.format_email_message(@workshop_planned, "created")

      assert message =~ "New Workshop Being Planned"
      assert message =~ "HEMA Open Session"
      assert message =~ "Dublin Fencing Club"
      assert message =~ "express your interest"
    end

    test "formats 'created' email for published workshop" do
      message = WorkshopAnnouncements.format_email_message(@workshop_published, "created")

      assert message =~ "Registration Now Open"
      assert message =~ "Longsword Basics"
    end

    test "formats 'status_changed' email for cancelled workshop" do
      message =
        WorkshopAnnouncements.format_email_message(@workshop_cancelled, "status_changed")

      assert message =~ "Cancelled Workshop"
      assert message =~ "Rapier Workshop"
    end

    test "formats 'time_changed' email" do
      message = WorkshopAnnouncements.format_email_message(@workshop_planned, "time_changed")

      assert message =~ "Schedule Change"
      assert message =~ "HEMA Open Session"
    end

    test "formats 'location_changed' email" do
      message = WorkshopAnnouncements.format_email_message(@workshop_planned, "location_changed")

      assert message =~ "Location Change"
      assert message =~ "will now be held at"
    end
  end

  describe "format_date/1" do
    test "formats DateTime into human-readable string" do
      dt = ~U[2024-03-15 18:00:00Z]
      formatted = WorkshopAnnouncements.format_date(dt)

      assert formatted == "March 15, 2024 at 06:00 PM"
    end

    test "formats ISO8601 string into human-readable string" do
      formatted = WorkshopAnnouncements.format_date("2024-03-15T18:00:00Z")
      assert formatted == "March 15, 2024 at 06:00 PM"
    end

    test "returns the string as-is if it cannot be parsed" do
      assert WorkshopAnnouncements.format_date("not-a-date") == "not-a-date"
    end
  end
end
