defmodule Dhc.Repo.Migrations.CreateMemberAnnouncements do
  @moduledoc """
  Member Announcements (ADR 0028): one row per committee email sent to many
  members at once.

  The row freezes everything a delivery retry needs — the rendered HTML and
  text, the subject, and the recipient addresses — so a retried job sends the
  same payload under the same Resend idempotency keys even if member data or
  the shell change in between.
  """

  use Ecto.Migration

  def change do
    create table(:member_announcements, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :subject, :text, null: false
      add :body, :map, null: false
      add :email_html, :text, null: false
      add :email_text, :text, null: false
      add :include_inactive, :boolean, null: false, default: false
      add :recipient_emails, {:array, :text}, null: false
      add :recipient_count, :integer, null: false
      add :status, :text, null: false, default: "queued"
      add :failure_reason, :text
      add :sent_at, :utc_datetime_usec

      add :sent_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      constraint(:member_announcements, :member_announcements_status_check,
        check: "status IN ('queued', 'sent', 'failed')"
      )
    )

    create(
      constraint(:member_announcements, :member_announcements_subject_check,
        check: "char_length(subject) > 0 AND char_length(subject) <= 200"
      )
    )

    create(
      constraint(:member_announcements, :member_announcements_recipient_count_check,
        check: "recipient_count = cardinality(recipient_emails) AND recipient_count > 0"
      )
    )

    create(index(:member_announcements, [:created_at]))
  end
end
