defmodule DhcWeb.WorkshopsJSON do
  @moduledoc false

  def render("calendar.json", %{workshops: workshops}) do
    %{data: %{workshops: Enum.map(workshops, &calendar_workshop/1)}}
  end

  defp calendar_workshop(workshop) do
    %{
      id: workshop.id,
      title: workshop.title,
      description: workshop.description,
      location: workshop.location,
      startDate: workshop.start_date,
      endDate: workshop.end_date,
      maxCapacity: workshop.max_capacity,
      priceMember: workshop.price_member,
      priceNonMember: workshop.price_non_member,
      isPublic: workshop.is_public,
      refundDays: workshop.refund_days,
      status: workshop.status,
      announceDiscord: workshop.announce_discord,
      announceEmail: workshop.announce_email,
      createdBy: workshop.created_by,
      interestCount: workshop.interest_count,
      pendingRegistrationCount: workshop.pending_registration_count,
      confirmedRegistrationCount: workshop.confirmed_registration_count
    }
  end
end
