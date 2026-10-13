defmodule Dhc.BeginnersWorkshops.IntakeReply do
  @moduledoc """
  One received Intake Reply (ALE-409, ADR 0030): what arrived and what we did
  with it, never what it said.

  The row holds the Resend email id (unique, so a redelivered webhook changes
  nothing), the reply-address binding it was sent to (`nil` when the address
  resolved to nothing), when it was received, the outcome with its reason,
  and the forward's sent id and time. It stores no body, subject or address.
  It is deleted with the person (`IntakeReplies.delete_for_person/1`).

  Outcomes: `pending` (recorded, not yet forwarded), `needs_you`,
  `unrecognised`, and — for Reply Actions (ALE-411) — `forwarded`, `done`,
  `automated` and `refused`.
  """

  use Ecto.Schema

  alias Dhc.BeginnersWorkshops.IntakeReplyAddress

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @outcomes ~w(pending forwarded done needs_you unrecognised automated refused)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          resend_email_id: String.t() | nil,
          reply_address_id: Ecto.UUID.t() | nil,
          reply_address: IntakeReplyAddress.t() | nil | Ecto.Association.NotLoaded.t(),
          received_at: DateTime.t() | nil,
          outcome: String.t(),
          outcome_reason: String.t() | nil,
          forward_sent_id: String.t() | nil,
          forwarded_at: DateTime.t() | nil
        }

  schema "beginners_workshop_intake_replies" do
    field :resend_email_id, :string
    belongs_to :reply_address, IntakeReplyAddress
    field :received_at, :utc_datetime_usec
    field :outcome, :string, default: "pending"
    field :outcome_reason, :string
    field :forward_sent_id, :string
    field :forwarded_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every outcome a reply can have."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes
end
