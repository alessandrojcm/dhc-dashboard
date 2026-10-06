defmodule DhcWeb.AuthHTTP do
  @moduledoc """
  The problem fallback for the Phoenix-session auth slice
  (`DhcWeb.AuthSessionController`).

  The magic-link request's non-enumerating `200` is not an error and stays
  in the controller; only the verify and Discord-link failures render here.
  The web magic-link page shows `errors.detail` of the `403`, so those
  details are user-facing copy.
  """

  use DhcWeb.Problem,
    reasons: %{
      invalid_link: {401, "Invalid or expired link"},
      inactive_membership:
        {403, "Your membership is inactive. Please contact the club to restore access."}
    }
end
