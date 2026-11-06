defmodule Dhc.TrainingCalendar.Grant do
  @moduledoc false

  use Ecto.Schema

  # Google user-rule IDs contain the recipient's address too.
  @derive {Inspect, except: [:email, :rule_id]}
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "training_calendar_grants" do
    field :calendar_id, :string
    field :email, :string
    field :rule_id, :string
    field :etag, :string

    timestamps(type: :utc_datetime_usec)
  end
end
