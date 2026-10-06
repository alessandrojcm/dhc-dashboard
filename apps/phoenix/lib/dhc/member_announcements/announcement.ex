defmodule Dhc.MemberAnnouncements.Announcement do
  @moduledoc """
  A Member Announcement row (ADR 0028). Written once by
  `Dhc.MemberAnnouncements.send_announcement/2`; afterwards only the delivery
  worker moves `status` from `queued` to `sent` or `failed`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type status :: :queued | :sent | :failed
  @type t :: %__MODULE__{}

  schema "member_announcements" do
    field :subject, :string
    field :body, :map
    field :email_html, :string
    field :email_text, :string
    field :include_inactive, :boolean, default: false
    field :recipient_emails, {:array, :string}
    field :recipient_count, :integer
    field :status, Ecto.Enum, values: [:queued, :sent, :failed], default: :queued
    field :failure_reason, :string
    field :sent_at, :utc_datetime_usec
    field :sent_by_principal_id, :binary_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
