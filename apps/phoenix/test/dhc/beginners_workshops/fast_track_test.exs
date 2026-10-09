defmodule Dhc.BeginnersWorkshops.FastTrackTest do
  @moduledoc """
  ALE-384: `fast_track` through `Dhc.BeginnersWorkshops.execute/3` with a
  fixed clock — the three ways to name a person (waiting, removed within
  retention, a new person through the staff path), every refusal, the
  `fast_track` Intake and its Contact email (`{{windowEnd}}` = the Payment
  Cutoff), and the Fast-track dialog's search.

  The workshop: Saturday 14 November 2026 at 18:30 Dublin, Payment Cutoff
  Wednesday 11 November 18:30 (GMT, so 18:30 UTC), 16 seats, €40.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BatchProposal, Clock, Intake, IntakeEmailLog}
  alias Dhc.BeginnersWorkshops.IntakeEmails.Template
  alias Dhc.Email.Worker
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-20 12:00:00Z]
  @cutoff ~U[2026-11-11 18:30:00Z]

  setup do
    coordinator = staff_fixture("beginners_coordinator")
    workshop = scheduled_fixture(coordinator)
    set_waitlist_open(false)
    %{coordinator: coordinator, workshop: workshop}
  end

  defp fast_track(staff, workshop, person, now \\ @now),
    do:
      BeginnersWorkshops.execute({:staff, staff}, {:fast_track, workshop.id, person},
        clock: Clock.fixed(now)
      )

  defp intakes(workshop),
    do: Repo.all(from(i in Intake, where: i.workshop_id == ^workshop.id))

  defp new_person(email, overrides \\ %{}) do
    Map.merge(
      %{
        "firstName" => "Ciara",
        "lastName" => "Referral",
        "email" => email,
        "phoneNumber" => "+353 1 000 0000",
        "dateOfBirth" => "1990-03-03",
        "gender" => "woman (cis)",
        "medicalConditions" => ""
      },
      overrides
    )
  end

  defp removed_person(removed_at) do
    entry = waiting_person_fixture(~U[2025-03-01 12:00:00Z], status: "removed")

    Repo.update_all(from(w in WaitlistEntry, where: w.id == ^entry.id),
      set: [removed_at: removed_at]
    )

    entry
  end

  defp set_waitlist_open(open?) do
    Repo.query!("UPDATE settings SET value = $1 WHERE key = 'waitlist_open'", [
      to_string(open?)
    ])
  end

  # The contact template as a paragraph of `names` placeholders joined by " / ".
  defp contact_template!(names) do
    content =
      names
      |> Enum.map(&%{"type" => "placeholder", "attrs" => %{"name" => &1}})
      |> Enum.intersperse(%{"type" => "text", "text" => " / "})

    Repo.update_all(Template |> where(email_type: "contact_pay"),
      set: [
        body: %{
          "type" => "doc",
          "content" => [%{"type" => "paragraph", "content" => content}]
        }
      ]
    )
  end

  describe "a waiting person" do
    test "gets a contacted fast-track Intake outside Batch order and the Contact email",
         %{coordinator: c, workshop: w} do
      _earlier = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      person = waiting_person_fixture(~U[2025-06-01 12:00:00Z], first_name: "Aoife")
      contact_template!(~w(windowEnd paymentCutoff))

      assert {:ok, %{origin: "fast_track", state: "contacted", placed: :waiting} = view} =
               fast_track(c, w, {:waitlist_entry, person.id})

      assert [
               %Intake{
                 id: intake_id,
                 origin: "fast_track",
                 batch_id: nil,
                 state: "contacted",
                 queue_date: ~U[2025-06-01 12:00:00Z],
                 contacted_at: contacted_at,
                 link_generation: 1
               }
             ] = intakes(w)

      assert view.id == intake_id
      assert DateTime.compare(contacted_at, @now) == :eq
      assert Repo.get!(WaitlistEntry, person.id).status == "waiting"

      # `{{windowEnd}}` renders the Payment Cutoff: a fast-track has no Batch.
      assert [%{args: %{"data_variables" => %{"MESSAGE_HTML" => html}}}] =
               all_enqueued(worker: Worker)

      assert html ==
               "<p>Wednesday 11 November 2026, 18:30 / Wednesday 11 November 2026, 18:30</p>"

      assert [%IntakeEmailLog{email_type: "contact_pay", occasion: "contact"}] =
               Repo.all(from(l in IntakeEmailLog, where: l.intake_id == ^intake_id))
    end

    test "charges the workshop fee: no waiver, and the fee locks", %{coordinator: c, workshop: w} do
      person = waiting_person_fixture(~U[2025-06-01 12:00:00Z])
      contact_template!(~w(fee))
      assert {:ok, _} = fast_track(c, w, {:waitlist_entry, person.id})

      assert [%{args: %{"data_variables" => %{"MESSAGE_HTML" => html}}}] =
               all_enqueued(worker: Worker)

      assert html == "<p>#{Dhc.BeginnersWorkshops.IntakeEmails.Values.money(4000)}</p>"

      assert {:error, :fee_locked} =
               BeginnersWorkshops.execute(
                 {:staff, c},
                 {:update_workshop, w.id, %{"fee_cents" => 0}},
                 clock: Clock.fixed(@now)
               )
    end

    test "leaves the Batch proposal", %{coordinator: c, workshop: w} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      assert [%{waitlist_id: id}] = BatchProposal.people(5)
      assert id == person.id

      assert {:ok, _} = fast_track(c, w, {:waitlist_entry, person.id})
      assert BatchProposal.people(5) == []
    end
  end

  describe "a removed person" do
    test "within 3 months is restored to waiting with the original priority",
         %{coordinator: c, workshop: w} do
      person = removed_person(~U[2026-07-21 12:00:00Z])

      assert {:ok, %{placed: :restored}} = fast_track(c, w, {:waitlist_entry, person.id})

      entry = Repo.get!(WaitlistEntry, person.id)
      assert entry.status == "waiting"
      assert entry.removed_at == nil
      assert entry.initial_registration_date == ~U[2025-03-01 12:00:00Z]
      assert [%Intake{queue_date: ~U[2025-03-01 12:00:00Z]}] = intakes(w)
    end

    test "after the retention window is not eligible", %{coordinator: c, workshop: w} do
      person = removed_person(~U[2026-07-20 11:59:59Z])

      assert {:error, :not_eligible} = fast_track(c, w, {:waitlist_entry, person.id})
      assert Repo.get!(WaitlistEntry, person.id).status == "removed"
      assert intakes(w) == []
    end
  end

  describe "a new person" do
    test "is added through the staff path while registration is closed, then fast-tracked",
         %{coordinator: c, workshop: w} do
      assert {:ok, %{placed: :added, waitlist_id: id}} =
               fast_track(c, w, {:new_person, new_person("Ciara@Example.com")})

      entry = Repo.get!(WaitlistEntry, id)
      assert entry.email == "ciara@example.com"
      assert entry.status == "waiting"
      assert entry.initial_registration_date == DateTime.truncate(@now, :second)
      assert Repo.get_by!(UserProfile, waitlist_id: id).first_name == "Ciara"
      assert [%Intake{waitlist_id: ^id, origin: "fast_track"}] = intakes(w)
      assert [_contact] = all_enqueued(worker: Worker)
    end

    test "is refused with the staff path's visible reasons", %{coordinator: c, workshop: w} do
      on_list = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

      assert {:error, :email_on_waitlist} =
               fast_track(c, w, {:new_person, new_person(on_list.email)})

      {:ok, _} =
        Dhc.Auth.register_principal_with_id(Ecto.UUID.generate(), %{email: "m@example.com"})

      assert {:error, :email_is_principal} =
               fast_track(c, w, {:new_person, new_person("M@example.com")})

      {:ok, _} =
        Dhc.Invitations.Repository.insert_pending_invitation(
          %{"email" => "invited@example.com", "dateOfBirth" => "1990-01-01"},
          nil,
          nil
        )

      assert {:error, :email_has_pending_invitation} =
               fast_track(c, w, {:new_person, new_person("invited@example.com")})

      assert {:error, :invalid_payload} =
               fast_track(c, w, {:new_person, new_person("x@example.com", %{"lastName" => ""})})

      assert intakes(w) == []
      assert all_enqueued(worker: Worker) == []
    end

    test "is not added when the Contact email cannot be queued", %{coordinator: c, workshop: w} do
      # A placeholder the contact email can't fill makes queueing fail.
      contact_template!(~w(refundAmount))

      assert {:error, _reason} = fast_track(c, w, {:new_person, new_person("roll@example.com")})
      refute Repo.get_by(WaitlistEntry, email: "roll@example.com")
      assert intakes(w) == []
    end
  end

  describe "refusals" do
    test "an open Intake, in this or another workshop", %{coordinator: c, workshop: w} do
      other = scheduled_fixture(c, %{"date" => "2026-11-21"})
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

      assert {:ok, %{id: intake_id}} = fast_track(c, other, {:waitlist_entry, person.id})
      assert {:error, :open_intake} = fast_track(c, w, {:waitlist_entry, person.id})
      assert {:error, :open_intake} = fast_track(c, other, {:waitlist_entry, person.id})

      force_intake_state!(intake_id, "paid")
      assert {:error, :open_intake} = fast_track(c, w, {:waitlist_entry, person.id})

      force_intake_state!(intake_id, "declined")
      assert {:ok, _} = fast_track(c, w, {:waitlist_entry, person.id})
    end

    for standing <- ~w(attended invited joined) do
      @standing standing
      test "#{standing} is not eligible", %{coordinator: c, workshop: w} do
        person = waiting_person_fixture(~U[2025-01-01 12:00:00Z], status: @standing)

        assert {:error, :not_eligible} = fast_track(c, w, {:waitlist_entry, person.id})
        assert intakes(w) == []
      end
    end

    test "after the Payment Cutoff", %{coordinator: c, workshop: w} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

      assert {:ok, _} =
               fast_track(c, w, {:waitlist_entry, person.id}, DateTime.add(@cutoff, -1, :second))

      other = waiting_person_fixture(~U[2025-02-01 12:00:00Z])
      assert {:error, :after_cutoff} = fast_track(c, w, {:waitlist_entry, other.id}, @cutoff)

      assert {:error, :after_cutoff} =
               fast_track(c, w, {:new_person, new_person("late@example.com")}, @cutoff)

      refute Repo.get_by(WaitlistEntry, email: "late@example.com")
    end

    test "a finalised or cancelled workshop", %{coordinator: c, workshop: w} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

      force_status!(w.id, "finalised")
      assert {:error, :after_finalisation} = fast_track(c, w, {:waitlist_entry, person.id})

      force_status!(w.id, "cancelled")
      assert {:error, :already_cancelled} = fast_track(c, w, {:waitlist_entry, person.id})
    end

    test "unknown workshops and people", %{coordinator: c, workshop: w} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

      assert {:error, :not_found} =
               fast_track(c, %{id: Ecto.UUID.generate()}, {:waitlist_entry, person.id})

      assert {:error, :person_not_found} =
               fast_track(c, w, {:waitlist_entry, Ecto.UUID.generate()})

      assert {:error, :person_not_found} = fast_track(c, w, {:waitlist_entry, "nope"})
      assert {:error, :invalid_payload} = fast_track(c, w, :someone)
    end

    test "an actor without beginners.workshops.manage", %{workshop: w} do
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      coach = staff_fixture("coach")

      assert {:error, :forbidden} = fast_track(coach, w, {:waitlist_entry, person.id})

      assert {:error, :forbidden} =
               BeginnersWorkshops.execute(
                 :system,
                 {:fast_track, w.id, {:waitlist_entry, person.id}}
               )
    end
  end

  describe "fast_track_candidates/3" do
    test "lists waiting and recently removed people without an open Intake, matching the search",
         %{coordinator: c, workshop: w} do
      aoife = waiting_person_fixture(~U[2025-01-01 12:00:00Z], first_name: "Aoife")
      bea = waiting_person_fixture(~U[2025-02-01 12:00:00Z], first_name: "Bea")
      recent = removed_person(~U[2026-07-21 12:00:00Z])
      _stale = removed_person(~U[2026-07-20 11:59:59Z])
      _attended = waiting_person_fixture(~U[2025-03-01 12:00:00Z], status: "attended")

      minor =
        waiting_person_fixture(~U[2025-04-01 12:00:00Z],
          first_name: "Young",
          date_of_birth: ~D[2010-01-01]
        )

      {:ok, _} = fast_track(c, w, {:waitlist_entry, bea.id})

      assert {:ok, rows} =
               BeginnersWorkshops.fast_track_candidates(w.id, nil, clock: Clock.fixed(@now))

      assert Enum.map(rows, & &1.waitlist_id) == [aoife.id, recent.id, minor.id]

      assert [
               %{status: "waiting", minor: false},
               %{status: "removed", removed_at: %DateTime{}},
               %{minor: true}
             ] = rows

      assert {:ok, [%{waitlist_id: id}]} =
               BeginnersWorkshops.fast_track_candidates(w.id, " aoi ", clock: Clock.fixed(@now))

      assert id == aoife.id

      assert {:ok, [%{waitlist_id: ^id}]} =
               BeginnersWorkshops.fast_track_candidates(w.id, aoife.email,
                 clock: Clock.fixed(@now)
               )

      assert {:ok, []} =
               BeginnersWorkshops.fast_track_candidates(w.id, "%", clock: Clock.fixed(@now))

      assert {:error, :not_found} =
               BeginnersWorkshops.fast_track_candidates(Ecto.UUID.generate(), nil)
    end
  end
end
