defmodule Dhc.Repo.Migrations.Ale287KeyedNotifications do
  @moduledoc """
  ALE-287: the keyed creation extension to the owning notification design.

  `Dhc.Notifications.create/2` is at-least-once by construction: a caller that
  crashes or retries after the commit creates a second row. Every notification
  ALE-280 asks for is emitted from a retryable context (an Oban reminder tick,
  a loan transition a client may resubmit), so the notification needs an
  application-supplied identity that makes creation idempotent.

  Adds:

    * `notifications.notification_key` — nullable, so every existing
      unkeyed caller (`Dhc.Invitations.Repository.create_processing_notification/2`)
      keeps working unchanged. A keyed caller names the *logical event*
      ("this loan's overdue reminder at this due-date revision"), never the
      recipient.
    * `notifications_principal_notification_key_unique` — partial unique index
      on `(principal_id, notification_key)` where the key is present. The
      recipient is part of the index rather than the key so one logical event
      (an overdue loan) can notify the borrower and every operator without the
      caller smuggling a principal id into the key string.

  The index is the *backstop*, not the mechanism: `create_keyed/3` upserts with
  `ON CONFLICT DO NOTHING` and reports whether it was the call that created the
  row, so a duplicate is a normal outcome and never a `Postgrex.Error`.

  Also constrains `inventory_loan_reminders.kind` (ALE-282 created the ledger
  with a free-text kind). The reminder occurrences ALE-280 story 51 asks for
  are one pre-due, one at overdue, then weekly, so the closed set is
  `pre_due`, `overdue`, and `overdue_week_<n>` — the week number is part of the
  kind because the ledger's unique key would otherwise collapse every weekly
  repeat onto one row.
  """

  use Ecto.Migration

  def up do
    alter table(:notifications) do
      add :notification_key, :text
    end

    create unique_index(
             :notifications,
             [:principal_id, :notification_key],
             where: "notification_key IS NOT NULL",
             name: :notifications_principal_notification_key_unique
           )

    execute """
    ALTER TABLE inventory_loan_reminders
      ADD CONSTRAINT inventory_loan_reminders_kind_check
      CHECK (kind IN ('pre_due', 'overdue') OR kind ~ '^overdue_week_[1-9][0-9]*$')
    """
  end

  def down do
    execute """
    ALTER TABLE inventory_loan_reminders
      DROP CONSTRAINT IF EXISTS inventory_loan_reminders_kind_check
    """

    drop index(:notifications, [:principal_id, :notification_key],
           name: :notifications_principal_notification_key_unique
         )

    alter table(:notifications) do
      remove :notification_key
    end
  end
end
