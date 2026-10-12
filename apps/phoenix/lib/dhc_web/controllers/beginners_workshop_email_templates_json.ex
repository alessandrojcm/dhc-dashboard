defmodule DhcWeb.BeginnersWorkshopEmailTemplatesJSON do
  @moduledoc false

  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.BeginnersWorkshops.IntakeEmails.Template

  def render("list.json", %{templates: templates}) do
    %{data: Enum.map(templates, &template/1)}
  end

  def render("show.json", %{template: template}) do
    %{data: template(template)}
  end

  defp template(%Template{} = template) do
    email_type = EmailType.fetch!(template.email_type)

    %{
      emailType: template.email_type,
      kind: email_type.kind,
      buttonLabel: email_type.button_label,
      placeholders: email_type.placeholders,
      subject: template.subject,
      body: template.body,
      updatedAt: template.updated_at
    }
  end
end
