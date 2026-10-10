defmodule DhcWeb.BeginnersWorkshopEmailTemplatesHTTP do
  @moduledoc """
  The problem fallback for the Intake Email template slice (ALE-383). The
  three save refusals are named 422 reasons; `fields.subject` /
  `fields.body` carry every message.
  """

  use DhcWeb.Problem,
    reasons: %{
      unknown_email_type: {404, "Intake Email type not found"},
      placeholder_not_allowed: {422, "The template uses a placeholder this email can't fill"},
      template_too_long:
        {422, "The message is over 2,000 characters with every placeholder at its longest"},
      invalid_template: {422, "The template is invalid"}
    }
end
