defmodule Dhc.TrainingAnnouncements.SchemasTest do
  use Dhc.DataCase, async: true

  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.AnnouncementOverride
  alias Dhc.TrainingAnnouncements.AnnouncementSuppression
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery

  defp announcement_fixture(attrs \\ %{}) do
    %Announcement{}
    |> Announcement.create_changeset(
      Map.merge(
        %{
          kind: "roll_call",
          weekday: 4,
          post_time: ~T[19:00:00],
          title: "Roll call {{date}}",
          message: "Who is coming?",
          mention_everyone: true
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "announcements" do
    test "creates weekly and one-off announcements" do
      weekly = announcement_fixture()
      assert weekly.kind == "roll_call"
      assert weekly.enabled == true
      assert weekly.retired == false
      assert weekly.first_attempted_at == nil

      one_off =
        announcement_fixture(%{kind: "sparring", weekday: nil, one_off_date: ~D[2025-09-27]})

      assert one_off.one_off_date == ~D[2025-09-27]
    end

    test "rejects unknown kinds" do
      changeset = Announcement.create_changeset(%Announcement{}, %{kind: "workshop"})

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "requires exactly one of weekday and one-off date" do
      both =
        Announcement.create_changeset(%Announcement{}, %{weekday: 4, one_off_date: ~D[2025-09-27]})

      assert %{one_off_date: [_]} = errors_on(both)

      neither = Announcement.create_changeset(%Announcement{}, %{})
      assert %{one_off_date: [_]} = errors_on(neither)
    end

    test "rejects bad copy at save" do
      bad =
        Announcement.create_changeset(%Announcement{}, %{
          kind: "roll_call",
          weekday: 4,
          post_time: ~T[19:00:00],
          title: "Roll call",
          message: "See you at {{startTime}}!"
        })

      assert %{message: [_]} = errors_on(bad)
    end

    test "kind cannot change after insert" do
      announcement = announcement_fixture()

      changeset =
        Announcement.update_changeset(announcement, %{kind: "sparring", title: "New title"})

      assert %{kind: ["kind never changes after creation"]} = errors_on(changeset)
    end

    test "the update changeset accepts the unchanged kind value" do
      announcement = announcement_fixture()

      changeset =
        Announcement.update_changeset(announcement, %{kind: "roll_call", title: "New title"})

      assert changeset.valid?
    end
  end

  describe "suppressions" do
    test "creates a single-date and a ranged suppression" do
      announcement = announcement_fixture()

      single =
        %AnnouncementSuppression{announcement_id: announcement.id}
        |> AnnouncementSuppression.changeset(%{
          from_date: ~D[2025-10-02],
          to_date: ~D[2025-10-02]
        })
        |> Repo.insert!()

      assert single.from_date == ~D[2025-10-02]

      ranged =
        %AnnouncementSuppression{announcement_id: announcement.id}
        |> AnnouncementSuppression.changeset(%{
          from_date: ~D[2025-10-02],
          to_date: ~D[2025-10-16]
        })
        |> Repo.insert!()

      assert ranged.to_date == ~D[2025-10-16]
    end

    test "rejects a range that ends before it starts" do
      announcement = announcement_fixture()

      changeset =
        AnnouncementSuppression.changeset(
          %AnnouncementSuppression{announcement_id: announcement.id},
          %{
            from_date: ~D[2025-10-16],
            to_date: ~D[2025-10-02]
          }
        )

      assert %{to_date: [_]} = errors_on(changeset)
    end
  end

  describe "overrides" do
    test "requires a title, a message, or both" do
      announcement = announcement_fixture()

      changeset =
        AnnouncementOverride.changeset(%AnnouncementOverride{announcement_id: announcement.id}, %{
          from_date: ~D[2025-10-02],
          to_date: ~D[2025-10-02],
          title: nil,
          message: nil
        })

      assert %{title: [_]} = errors_on(changeset)
    end

    test "rejects overlapping ranges for the same announcement" do
      announcement = announcement_fixture()

      %AnnouncementOverride{announcement_id: announcement.id}
      |> AnnouncementOverride.changeset(%{
        from_date: ~D[2025-10-02],
        to_date: ~D[2025-10-09],
        title: "Special"
      })
      |> Repo.insert!()

      {:error, changeset} =
        %AnnouncementOverride{announcement_id: announcement.id}
        |> AnnouncementOverride.changeset(%{
          from_date: ~D[2025-10-09],
          to_date: ~D[2025-10-16],
          title: "Overlapping on the 9th"
        })
        |> Repo.insert()

      assert %{from_date: ["overlaps another override for this announcement"]} =
               errors_on(changeset)
    end

    test "allows disjoint ranges and same dates on other announcements" do
      first = announcement_fixture()
      second = announcement_fixture(%{weekday: 7})

      %AnnouncementOverride{announcement_id: first.id}
      |> AnnouncementOverride.changeset(%{
        from_date: ~D[2025-10-02],
        to_date: ~D[2025-10-02],
        title: "A"
      })
      |> Repo.insert!()

      disjoint =
        %AnnouncementOverride{announcement_id: first.id}
        |> AnnouncementOverride.changeset(%{
          from_date: ~D[2025-10-09],
          to_date: ~D[2025-10-09],
          title: "B"
        })
        |> Repo.insert!()

      assert disjoint.title == "B"

      other_announcement =
        %AnnouncementOverride{announcement_id: second.id}
        |> AnnouncementOverride.changeset(%{
          from_date: ~D[2025-10-02],
          to_date: ~D[2025-10-02],
          title: "C"
        })
        |> Repo.insert!()

      assert other_announcement.title == "C"
    end
  end

  describe "deliveries" do
    test "records an occurrence delivery and fences duplicates" do
      announcement = announcement_fixture()

      %DiscordAnnouncementDelivery{announcement_id: announcement.id}
      |> DiscordAnnouncementDelivery.changeset(%{
        subject: "occurrence",
        occurrence_date: ~D[2025-09-25],
        state: "skipped",
        reason: "suppressed"
      })
      |> Repo.insert!()

      {:error, changeset} =
        %DiscordAnnouncementDelivery{announcement_id: announcement.id}
        |> DiscordAnnouncementDelivery.changeset(%{
          subject: "occurrence",
          occurrence_date: ~D[2025-09-25],
          state: "missed"
        })
        |> Repo.insert()

      assert %{announcement_id: [_]} = errors_on(changeset)
    end

    test "records holiday deliveries per date and phase" do
      %DiscordAnnouncementDelivery{}
      |> DiscordAnnouncementDelivery.changeset(%{
        subject: "holiday",
        holiday_date: ~D[2025-10-27],
        phase: "same_day",
        state: "delivered",
        discord_message_id: "123"
      })
      |> Repo.insert!()

      {:error, changeset} =
        %DiscordAnnouncementDelivery{}
        |> DiscordAnnouncementDelivery.changeset(%{
          subject: "holiday",
          holiday_date: ~D[2025-10-27],
          phase: "same_day",
          state: "blocked"
        })
        |> Repo.insert()

      assert %{holiday_date: [_]} = errors_on(changeset)

      other_phase =
        %DiscordAnnouncementDelivery{}
        |> DiscordAnnouncementDelivery.changeset(%{
          subject: "holiday",
          holiday_date: ~D[2025-10-27],
          phase: "day_before",
          state: "delivered"
        })
        |> Repo.insert!()

      assert other_phase.phase == "day_before"
    end

    test "the subject check ties the discriminator to its columns" do
      announcement = announcement_fixture()

      {:error, changeset} =
        %DiscordAnnouncementDelivery{announcement_id: announcement.id}
        |> DiscordAnnouncementDelivery.changeset(%{
          subject: "occurrence",
          occurrence_date: ~D[2025-09-25],
          holiday_date: ~D[2025-09-25],
          state: "blocked"
        })
        |> Repo.insert()

      assert %{subject: [_]} = errors_on(changeset)
    end

    test "deleting an exception clears the delivery evidence link" do
      announcement = announcement_fixture()

      suppression =
        %AnnouncementSuppression{announcement_id: announcement.id}
        |> AnnouncementSuppression.changeset(%{
          from_date: ~D[2025-10-02],
          to_date: ~D[2025-10-02]
        })
        |> Repo.insert!()

      delivery =
        %DiscordAnnouncementDelivery{
          announcement_id: announcement.id,
          applied_suppression_id: suppression.id
        }
        |> DiscordAnnouncementDelivery.changeset(%{
          subject: "occurrence",
          occurrence_date: ~D[2025-10-02],
          state: "skipped",
          reason: "suppressed"
        })
        |> Repo.insert!()

      Repo.delete!(suppression)

      assert Repo.reload!(delivery).applied_suppression_id == nil
    end

    test "deleting a never-attempted announcement cascades its rows" do
      announcement = announcement_fixture()

      %DiscordAnnouncementDelivery{announcement_id: announcement.id}
      |> DiscordAnnouncementDelivery.changeset(%{
        subject: "occurrence",
        occurrence_date: ~D[2025-09-25],
        state: "skipped",
        reason: "suppressed"
      })
      |> Repo.insert!()

      Repo.delete!(announcement)

      assert Repo.aggregate(DiscordAnnouncementDelivery, :count) == 0
    end
  end
end
