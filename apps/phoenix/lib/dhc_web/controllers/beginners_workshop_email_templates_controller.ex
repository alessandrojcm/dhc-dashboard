defmodule DhcWeb.BeginnersWorkshopEmailTemplatesController do
  @moduledoc """
  The Intake Email template slice of Beginners' Workshops (ALE-383). Gated by
  the `:beginners_workshops_manage` pipeline; every action delegates to
  `Dhc.BeginnersWorkshops.IntakeEmails`.
  """

  use DhcWeb, :controller

  alias Dhc.BeginnersWorkshops.IntakeEmails

  action_fallback DhcWeb.BeginnersWorkshopEmailTemplatesHTTP

  @doc "GET /beginners-workshops/email-templates"
  def list(conn, _params) do
    render(conn, :list, templates: IntakeEmails.list_templates())
  end

  @doc "PUT /beginners-workshops/email-templates/:emailType"
  def update(conn, %{"emailType" => type} = params) do
    attrs = Map.take(params, ["subject", "body"])

    with {:ok, template} <- IntakeEmails.update_template(type, attrs) do
      render(conn, :show, template: template)
    end
  end
end
