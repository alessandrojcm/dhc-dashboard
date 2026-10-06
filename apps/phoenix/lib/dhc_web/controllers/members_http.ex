defmodule DhcWeb.MembersHTTP do
  @moduledoc """
  The problem fallback for the Members and Membership HTTP slices.

  `Dhc.Membership` answers every Stripe failure with `:stripe_error` and every
  malformed body with `:invalid_payload`; `DhcWeb.MembershipController`
  renames them per action so each keeps its own detail while sharing the
  public `invalid_payload` code.
  """

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "Member not found"},
      invalid_query: {400, "Invalid members query"},
      invalid_payload: {422, "Invalid member update payload"},
      forbidden: {403, "Insufficient role"},
      invalid_roles: {422, "Select valid, distinct club roles and provide the current roles"},
      roles_changed: {409, "Roles changed since you opened this editor. Reload before saving."},
      last_role_editor: {409, "Keep at least one active president or admin to manage roles"},
      invalid_pause: {422, "Invalid membership pause payload", :invalid_payload},
      invalid_return_url: {422, "Invalid billing portal return URL", :invalid_payload},
      invalid_billing_portal: {422, "Invalid billing portal payload", :invalid_payload},
      invalid_reactivation: {422, "Invalid membership reactivation payload", :invalid_payload},
      invalid_reactivation_amounts:
        {422, "Invalid membership reactivation amounts payload", :invalid_payload},
      subscription_not_found: {409, "Membership subscription not found"},
      membership_paused: {409, "Member's membership subscription is paused"},
      membership_active: {409, "Member already has an active membership subscription"},
      no_saved_payment_method:
        {409,
         "Member has no usable saved SEPA payment method; use the billing portal as fallback"},
      stripe_error: {502, "Stripe membership update failed"},
      billing_portal_failed: {502, "Stripe billing portal request failed"},
      reactivation_failed: {502, "Stripe membership reactivation failed"},
      payment_method_lookup_failed: {502, "Stripe payment-method lookup failed"},
      cost_preview_failed: {502, "Stripe membership cost preview failed"}
    },
    fields: %{
      first_name: "firstName",
      last_name: "lastName",
      date_of_birth: "dateOfBirth",
      phone_number: "phoneNumber",
      preferred_weapon: "preferredWeapon",
      next_of_kin_name: "nextOfKinName",
      next_of_kin_phone: "nextOfKinPhone",
      medical_conditions: "medicalConditions",
      pronouns: "pronouns",
      gender: "gender",
      insurance_form_submitted: "insuranceFormSubmitted",
      social_media_consent: "socialMediaConsent",
      subscription_paused_until: "pauseUntil"
    }
end
