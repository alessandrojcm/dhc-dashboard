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
