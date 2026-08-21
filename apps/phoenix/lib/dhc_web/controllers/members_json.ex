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

  def render("current_user.json", %{user: user, roles: roles}) do
    %{
      data: %{
        id: user.id,
        firstName: user.first_name,
        lastName: user.last_name,
        email: user.email,
        phoneNumber: user.phone_number,
        customerId: user.customer_id,
        roles: roles
      }
    }
  end

  def render("show.json", %{member: member}) do
    %{data: member(member)}
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

  def render("options.json", %{options: options}) do
    %{data: %{genders: options.genders, weapons: options.weapons}}
  end

  defp member(member) do
    %{
      id: member.id,
      firstName: member.first_name,
      lastName: member.last_name,
      email: member.email,
      phoneNumber: member.phone_number,
      dateOfBirth: member.date_of_birth,
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
      membershipStatus: member.membership_status,
      discordIdentity: discord_identity(Map.get(member, :discord_identity))
    }
  end

  defp discord_identity(nil), do: nil

  defp discord_identity(identity) do
    %{
      username: identity.username,
      avatarUrl: identity.avatar_url
    }
  end
end
