defmodule DhcWeb.WaitlistHTTP do
  @moduledoc "The problem fallback for the Waitlist HTTP slice."

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "Waitlist entry not found"},
      setting_not_found: {404, "Waitlist setting not found"},
      invalid_query: {400, "Invalid waitlist entries query"},
      waitlist_closed: {403, "Waitlist is closed"},
      invalid_is_open: {422, "isOpen must be a boolean"},
      invalid_payload: {422, "Invalid waitlist entry payload"},
      invalid_update: {422, "Invalid waitlist entry update payload", :invalid_payload}
    },
    fields: %{
      first_name: "firstName",
      last_name: "lastName",
      date_of_birth: "dateOfBirth",
      phone_number: "phoneNumber",
      medical_conditions: "medicalConditions",
      social_media_consent: "socialMediaConsent",
      admin_notes: "adminNotes"
    }
end
