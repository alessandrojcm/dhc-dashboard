defmodule DhcWeb.BeginnersWorkshopIntakeHTTP do
  @moduledoc """
  The problem fallback of the public Intake link slice (ALE-381). An
  unknown link is a plain 404; the Intake page renders it like a closed
  Intake ("no longer active"), so a guessed token learns nothing.
  """

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "This link is no longer active"},
      after_cutoff: {409, "Payment for this workshop has closed"},
      full: {409, "Every seat is taken right now"},
      already_paid: {409, "Your place is already paid"},
      intake_closed: {409, "This link is no longer active"},
      payment_in_progress: {409, "Your payment is still being confirmed"},
      # Carried Fees (ALE-388).
      confirm_instead: {409, "You have a Carried Fee: confirm your place instead of paying"},
      no_carried_fee: {409, "There is no Carried Fee to confirm this place with"},
      payment_unavailable: {503, "Payment is unavailable right now; please try again shortly"}
    }
end
