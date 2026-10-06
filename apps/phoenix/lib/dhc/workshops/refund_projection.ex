defmodule Dhc.Workshops.RefundProjection do
  @moduledoc """
  ALE-340: the one coordinator-facing Refund read model.

  `Dhc.Workshops.list_workshop_refunds/1` and the Refund commands in
  `Dhc.Workshops.PaymentCommands` both project through `project/2`, so the
  row a coordinator just requested and the row the list returns cannot
  disagree, and the HTTP layer needs no second read after a command.

  Participant identity is the Registration's attendee snapshot
  (`display_name`, `email`, ALE-181); the participant FK column only decides
  the participant type.
  """

  alias Dhc.Workshops.{Refund, Registration}

  @type participant :: %{
          type: :member | :external,
          display_name: String.t() | nil,
          email: String.t() | nil
        }

  @type t :: %{
          id: binary(),
          registration_id: binary() | nil,
          refund_amount: integer(),
          refund_reason: String.t() | nil,
          status: String.t(),
          stripe_refund_id: String.t() | nil,
          requested_at: DateTime.t() | nil,
          processed_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          participant: participant()
        }

  @doc "Projects a Registration Refund for coordinators."
  @spec project(Refund.t(), Registration.t()) :: t()
  def project(%Refund{} = refund, %Registration{} = registration) do
    %{
      id: refund.id,
      registration_id: refund.registration_id,
      refund_amount: refund.refund_amount,
      refund_reason: refund.refund_reason,
      status: refund.status,
      stripe_refund_id: refund.stripe_refund_id,
      requested_at: refund.requested_at,
      processed_at: refund.processed_at,
      completed_at: refund.completed_at,
      participant: participant(registration)
    }
  end

  defp participant(%Registration{member_user_id: nil, external_user_id: id} = registration)
       when not is_nil(id),
       do: %{type: :external, display_name: registration.display_name, email: registration.email}

  defp participant(%Registration{member_user_id: id} = registration) when not is_nil(id),
    do: %{type: :member, display_name: registration.display_name, email: registration.email}
end
