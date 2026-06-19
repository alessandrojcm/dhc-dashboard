defmodule DhcWeb.MembersJSON do
  @moduledoc false

  def render("index.json", %{result: result}) do
    %{
      data: %{
        members: Enum.map(result.members, &member/1),
        totalCount: result.total_count,
        limit: result.limit,
        nextCursor: result.next_cursor,
        previousCursor: result.previous_cursor
      }
    }
  end

  def render("insurance_form.json", %{insurance_form: insurance_form}) do
    %{data: %{link: insurance_form.link}}
  end

  def render("analytics.json", %{analytics: analytics}) do
    %{
      data: %{
        totalCount: analytics.total_count,
        averageAge: analytics.average_age,
        genderDistribution: analytics.gender_distribution,
        ageDistribution: analytics.age_distribution,
        weaponDistribution: analytics.weapon_distribution
      }
    }
  end

  defp member(member) do
    %{
      id: member.id,
      firstName: member.first_name,
      lastName: member.last_name,
      email: member.email,
      phoneNumber: member.phone_number,
      gender: member.gender,
      pronouns: member.pronouns,
      isActive: member.is_active,
      preferredWeapon: member.preferred_weapon,
      membershipStartDate: member.membership_start_date,
      membershipEndDate: member.membership_end_date,
      lastPaymentDate: member.last_payment_date,
      insuranceFormSubmitted: member.insurance_form_submitted,
      age: member.age,
      socialMediaConsent: member.social_media_consent,
      nextOfKinName: member.next_of_kin_name,
      nextOfKinPhone: member.next_of_kin_phone,
      guardianFirstName: member.guardian_first_name,
      guardianLastName: member.guardian_last_name,
      guardianPhoneNumber: member.guardian_phone_number,
      medicalConditions: member.medical_conditions,
      subscriptionPausedUntil: member.subscription_paused_until,
      membershipStatus: member.membership_status
    }
  end
end
