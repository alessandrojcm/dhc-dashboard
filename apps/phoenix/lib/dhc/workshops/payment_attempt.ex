defmodule Dhc.Workshops.PaymentAttempt do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "club_activity_payment_attempts" do
    field :club_activity_id, :binary_id
    field :member_user_id, :binary_id
    field :external_email, :string
    field :actor_type, :string
    field :amount, :integer
    field :currency, :string, default: "eur"
    field :status, :string, default: "pending"
    field :stripe_payment_intent_id, :string
    field :stripe_checkout_session_id, :string
    field :paid_at, :utc_datetime
    field :concluded_at, :utc_datetime

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
