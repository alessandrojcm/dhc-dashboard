defmodule Dhc.Repo.Migrations.Ale299WebPushSubscriptions do
  @moduledoc """
  ALE-299: per-browser Web Push subscriptions for the notification centre.

  A row is one *browser installation* a member opted in from, not the member:
  a phone PWA and a laptop browser are two rows for the same principal, and
  each can be revoked on its own (the push service reports a dead endpoint per
  subscription, and the member disables push per device).

    * `endpoint` is unique on its own, not per principal. The push service
      mints one endpoint per browser installation, so the same endpoint
      re-registered by a different principal (a shared device, or a sign-out
      followed by another member's sign-in) is a *reassignment*, not a second
      subscription — the browser can only be delivering for whoever is signed
      in. `WebPush.subscribe/2` upserts on this constraint.
    * `p256dh`/`auth` are the browser's public key and auth secret, needed to
      encrypt every payload for that browser (RFC 8291). They are never
      returned by the API.
    * `principal_id` cascades on delete so removing a member removes the
      channels that would otherwise keep addressing their devices.
  """

  use Ecto.Migration

  def change do
    create table(:notification_push_subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :principal_id,
          references(:principals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :user_agent, :text

      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:notification_push_subscriptions, [:endpoint],
             name: :notification_push_subscriptions_endpoint_unique
           )

    create index(:notification_push_subscriptions, [:principal_id])
  end
end
