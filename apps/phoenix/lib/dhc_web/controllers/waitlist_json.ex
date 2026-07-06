defmodule DhcWeb.WaitlistJSON do
  @moduledoc false

  def render("status.json", %{status: status}) do
    %{data: %{isOpen: status.is_open}}
  end

  def render("analytics.json", %{analytics: analytics}) do
    %{
      data: %{
        totalCount: analytics.total_count,
        averageAge: analytics.average_age,
        genderDistribution: analytics.gender_distribution,
        ageDistribution: analytics.age_distribution
      }
    }
  end

  def render("entries.json", %{result: result}) do
    %{
      data: %{
        entries: Enum.map(result.entries, &entry/1),
        totalCount: result.total_count,
        limit: result.limit,
        nextCursor: result.next_cursor,
        previousCursor: result.previous_cursor
      }
    }
  end

  def render("create.json", %{entry: entry}) do
    %{
      data: %{
        id: entry.id,
        status: entry.status
      }
    }
  end

  def render("show.json", %{entry: entry}) do
    %{data: entry(entry)}
  end

  def render("guardian.json", %{guardian: nil}) do
    %{data: nil}
  end

  def render("guardian.json", %{guardian: guardian}) do
    %{
      data: %{
        firstName: guardian.first_name,
        lastName: guardian.last_name,
        phoneNumber: guardian.phone_number
      }
    }
  end

  defp entry(entry) do
    %{
      id: entry.id,
      position: entry.position,
      fullName: entry.full_name,
      email: entry.email,
      phoneNumber: entry.phone_number,
      status: entry.status,
      age: entry.age,
      initialRegistrationDate: entry.initial_registration_date,
      lastContacted: entry.last_contacted,
      medicalConditions: entry.medical_conditions,
      adminNotes: entry.admin_notes,
      socialMediaConsent: entry.social_media_consent,
      guardianFirstName: entry.guardian_first_name,
      guardianLastName: entry.guardian_last_name,
      guardianPhoneNumber: entry.guardian_phone_number,
      insuranceFormSubmitted: entry.insurance_form_submitted,
      lastStatusChange: entry.last_status_change
    }
  end
end
