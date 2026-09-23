defmodule Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery do
  @moduledoc """
  Ecto schema for `discord_announcement_deliveries`: the one durable Discord
  progression for an Announcement Occurrence (`subject = "occurrence"`,
  identified by announcement + Europe/Dublin date) or a Holiday Announcement
  (`subject = "holiday"`, identified by holiday date + phase
  `day_before | same_day`).

  The partial unique indexes are the only duplicate fence — a racing second
  job simply fails its insert. The subject CHECK ties the discriminator to
  its populated columns, so an occurrence row can never carry holiday fields
  and vice versa. Monotonic checkpoints (`frozen_at` … `concluded_at`) and
  provider ids are written as soon as they are known and never erased;
  `error_detail` is capped near 500 characters. `applied_suppression_id` and
  `applied_override_id` are evidence, not links: deleting the exception
  clears them (`ON DELETE SET NULL`) while the delivery row stands.

  Glossary (`CONTEXT.md`): "The one durable Discord progression for an
  Announcement Occurrence or a Holiday Announcement, identified by what it
  announces and its Europe/Dublin date."
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @subjects ~w(occurrence holiday)
  @phases ~w(day_before same_day)
  @kinds ~w(roll_call sparring)
  @states ~w(frozen posting_message message_posted creating_thread delivered message_uncertain thread_failed blocked skipped missed)
  @reasons ~w(holiday disabled suppressed unconfigured_channel invalid_copy late permission unknown_channel payload_rejected timeout server_error worker_lost unknown)

  schema "discord_announcement_deliveries" do
    field :subject, :string
    field :occurrence_date, :date
    field :holiday_date, :date
    field :phase, :string

    field :post_time, :time
    field :kind, :string
    field :mention_everyone, :boolean
    field :title_source, :string
    field :message_source, :string
    field :rendered_message, :string
    field :thread_name, :string
    field :channel_id, :string

    field :state, :string
    field :reason, :string

    field :frozen_at, :utc_datetime_usec
    field :posting_started_at, :utc_datetime_usec
    field :message_posted_at, :utc_datetime_usec
    field :thread_created_at, :utc_datetime_usec
    field :concluded_at, :utc_datetime_usec

    field :discord_message_id, :string
    field :discord_thread_id, :string
    field :error_detail, :string
    field :thread_attempts, :integer, default: 0
    field :last_thread_error, :string

    belongs_to :announcement, Dhc.TrainingAnnouncements.Announcement

    belongs_to :applied_suppression, Dhc.TrainingAnnouncements.AnnouncementSuppression,
      foreign_key: :applied_suppression_id

    belongs_to :applied_override, Dhc.TrainingAnnouncements.AnnouncementOverride,
      foreign_key: :applied_override_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :subject,
      :occurrence_date,
      :holiday_date,
      :phase,
      :post_time,
      :kind,
      :mention_everyone,
      :title_source,
      :message_source,
      :rendered_message,
      :thread_name,
      :channel_id,
      :state,
      :reason,
      :frozen_at,
      :posting_started_at,
      :message_posted_at,
      :thread_created_at,
      :concluded_at,
      :discord_message_id,
      :discord_thread_id,
      :error_detail,
      :thread_attempts,
      :last_thread_error
    ])
    |> validate_required([:subject, :state])
    |> validate_inclusion(:subject, @subjects)
    |> validate_inclusion(:phase, @phases)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:reason, @reasons)
    |> validate_number(:thread_attempts, greater_than_or_equal_to: 0)
    |> validate_length(:error_detail, max: 500)
    |> foreign_key_constraint(:announcement_id)
    |> foreign_key_constraint(:applied_suppression_id)
    |> foreign_key_constraint(:applied_override_id)
    |> unique_constraint([:announcement_id, :occurrence_date],
      name: :discord_announcement_deliveries_occurrence_unique
    )
    |> unique_constraint([:holiday_date, :phase],
      name: :discord_announcement_deliveries_holiday_unique
    )
    |> check_constraint(:subject, name: :discord_announcement_deliveries_subject_shape_check)
    |> check_constraint(:state, name: :discord_announcement_deliveries_state_check)
    |> check_constraint(:reason, name: :discord_announcement_deliveries_reason_check)
    |> check_constraint(:kind, name: :discord_announcement_deliveries_kind_check)
    |> check_constraint(:thread_attempts,
      name: :discord_announcement_deliveries_thread_attempts_check
    )
  end
end
