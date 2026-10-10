defmodule Dhc.BeginnersWorkshops.IntakeEmails.Template do
  @moduledoc """
  The club-wide template of one Intake Email type (ALE-377): a plain-text
  subject with `{{placeholder}}` tokens and a Tiptap body. One row per
  `EmailType`, seeded by the migration; rows are edited, never created or
  deleted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer

  @primary_key {:email_type, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "beginners_workshop_email_templates" do
    field :subject, :string
    field :body, :map

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "An edit, refused unless the template only uses its type's placeholders and fits."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = template, attrs) do
    template
    |> cast(attrs, [:subject, :body])
    |> validate_required([:subject, :body])
    |> validate_template()
  end

  defp validate_template(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_template(changeset) do
    type = fetch_field!(changeset, :email_type)

    case Renderer.validate(type, get_field(changeset, :subject), get_field(changeset, :body)) do
      :ok ->
        changeset

      {:error, errors} ->
        Enum.reduce(errors, changeset, fn {field, refusal, message}, acc ->
          add_error(acc, field, message, refusal: refusal)
        end)
    end
  end
end
