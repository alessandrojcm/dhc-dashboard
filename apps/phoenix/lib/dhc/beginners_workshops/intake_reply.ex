defmodule Dhc.BeginnersWorkshops.IntakeReply do
  @moduledoc """
  One received Intake Reply (ALE-409, ADR 0030): what arrived and what we did
  with it, never what it said.

  The row holds the Resend email id (unique, so a redelivered webhook changes
  nothing), the reply-address binding it was sent to (`nil` when the address
  resolved to nothing), when it was received, the outcome with its reason,
  and the forward's sent id and time. For Reply Actions (ALE-411) it also
  holds Jev's answers (`intent`, `intent_probabilities`,
  `intent_confidence`, `money_back`, `model`), the command chosen
  (`command`, written before it runs) and when the outcome was decided
  (`decided_at`), and, for a Reply Action that leaves no Intake history row
  (ALE-412's restore), when it committed (`action_committed_at`, stamped in
  the command's transaction). It stores no body, subject or address. It is deleted with
  the person (`IntakeReplies.delete_for_person/1`).

  Outcomes: `pending` (recorded, not yet decided), `done` (a Reply Action
  ran), `needs_you` (no Reply Action: the reason says why), `refused` (the
  boundary refused the Reply Action, or found it already done),
  `automated` (an auto-reply) and `unrecognised` (an address that matches
  nobody). `forwarded` is unused.
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
          forwarded_at: DateTime.t() | nil,
          intent: String.t() | nil,
          intent_probabilities: %{String.t() => number()} | nil,
          intent_confidence: float() | nil,
          money_back: float() | nil,
          model: String.t() | nil,
          command: String.t() | nil,
          decided_at: DateTime.t() | nil,
          action_committed_at: DateTime.t() | nil
        }

  schema "beginners_workshop_intake_replies" do
    field :resend_email_id, :string
    belongs_to :reply_address, IntakeReplyAddress
    field :received_at, :utc_datetime_usec
    field :outcome, :string, default: "pending"
    field :outcome_reason, :string
    field :forward_sent_id, :string
    field :forwarded_at, :utc_datetime_usec
    field :intent, :string
    field :intent_probabilities, :map
    field :intent_confidence, :float
    field :money_back, :float
    field :model, :string
    field :command, :string
    field :decided_at, :utc_datetime_usec
    field :action_committed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Stamps that the reply's Reply Action committed (ALE-412), for a command
  that writes no Intake history row naming the reply. The command persists
  it in its own transaction; `IntakeReplies.Decision` reads it on a retry.
  """
  @spec action_committed_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def action_committed_changeset(%__MODULE__{} = reply, %DateTime{} = now),
    do: Ecto.Changeset.change(reply, action_committed_at: now)

  @doc "Every outcome a reply can have."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes
end
