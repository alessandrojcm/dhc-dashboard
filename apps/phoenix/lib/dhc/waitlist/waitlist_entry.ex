defmodule Dhc.Waitlist.WaitlistEntry do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "waitlist" do
    field :email, :string
    field :status, :string
    field :initial_registration_date, :utc_datetime
    field :last_status_change, :utc_datetime
    field :last_contacted, :utc_datetime
    field :admin_notes, :string
  end
end
