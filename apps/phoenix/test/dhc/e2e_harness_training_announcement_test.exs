defmodule Dhc.E2EHarnessTrainingAnnouncementTest do
  @moduledoc """
  ALE-334: round-trip for the `trainingAnnouncement` E2E scenario.

  Seeds a weekly announcement plus one past `delivered` delivery row through
  `Dhc.E2EHarness`, asserts the evidence is served by the occurrence read
  model (the payload the inspector renders), then deletes through the
  harness and proves clean teardown. Also covers the never-attempted path
  and the actor requirement.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.UserRole
  alias Dhc.E2EHarness
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery

  setup do
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})
    %{actor: member.principal_id}
  end

  test "seed creates an announcement with past delivered evidence and deletes cleanly",
       %{actor: actor} do
    result =
      E2EHarness.seed("trainingAnnouncement", %{
        "actorId" => actor,
        "title" => "E2E smoke {{date}}",
        "message" => "E2E smoke {{weekday}}"
      })

    assert result.announcementId != nil
    assert result.kind == "roll_call"
    assert result.title == "E2E smoke {{date}}"
    assert result.threadName =~ "E2E smoke"
    assert result.occurrenceDate =~ ~r/^\d{4}-\d{2}-\d{2}$/
    assert result.deliveryId != nil

    announcement = Repo.get!(Announcement, result.announcementId)
    assert announcement.first_attempted_at != nil

    assert Repo.get!(DiscordAnnouncementDelivery, result.deliveryId).state == "delivered"

    # The past row is served as a past window item with inspector evidence.
    from = Date.from_iso8601!(result.occurrenceDate)
    today = Dhc.ClubCalendar.today()
    assert Date.compare(from, today) == :lt
    assert {:ok, items} = TrainingAnnouncements.occurrence_window(actor, from, today)

    item =
      Enum.find(items, &(&1.announcement_id == result.announcementId and &1.date == from))

    assert item != nil
    assert item.delivery != nil
    assert item.delivery.state == "delivered"
    assert item.outcome == "post"
    assert item.thread_name == result.threadName

    assert :ok = E2EHarness.delete_fixture("trainingAnnouncement", result.announcementId)
    assert Repo.get(Announcement, result.announcementId) == nil
    assert Repo.get(DiscordAnnouncementDelivery, result.deliveryId) == nil

    assert {:error, :not_found} =
             E2EHarness.delete_fixture("trainingAnnouncement", result.announcementId)
  end

  test "delete removes a never-attempted announcement", %{actor: actor} do
    tomorrow = Date.add(Dhc.ClubCalendar.today(), 1)

    {:ok, %{announcement: announcement}} =
      TrainingAnnouncements.create(actor, %{
        "kind" => "sparring",
        "weekday" => Date.day_of_week(tomorrow),
        "post_time" => "19:00",
        "title" => "Sparring {{date}}",
        "message" => "Hey! Who is down for sparring this {{weekday}}? ⚔️",
        "mention_everyone" => true
      })

    assert announcement.first_attempted_at == nil
    assert :ok = E2EHarness.delete_fixture("trainingAnnouncement", announcement.id)
    assert Repo.get(Announcement, announcement.id) == nil
  end

  test "seed requires a management-role operator" do
    outsider = Dhc.MemberFixtures.member_fixture().principal_id

    assert {:error, :forbidden} =
             E2EHarness.seed("trainingAnnouncement", %{"actorId" => outsider})

    assert_raise ArgumentError, ~r/actorId/, fn ->
      E2EHarness.seed("trainingAnnouncement", %{})
    end
  end
end
