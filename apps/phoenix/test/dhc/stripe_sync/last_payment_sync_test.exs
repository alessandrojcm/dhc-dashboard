defmodule Dhc.StripeSync.LastPaymentSyncTest do
  @moduledoc """
  Regression test: the Stripe sync must request `expand[]=data.latest_invoice`
  when listing subscriptions so `resolve_last_payment_date/1` can read the
  latest invoice's `status_transitions.paid_at`.

  Without the expansion, Stripe's list endpoint returns `latest_invoice` as a
  bare string ID. The paid_at lookup then always misses and every active
  member's `last_payment_date` collapses to the subscription's original
  `start_date` — a member paying monthly since last year shows "last payment:
  last year" forever.

  The fake Stripe endpoint mimics real expansion semantics: it only returns an
  expanded invoice object when the request carries the `expand[]` param.
  """

  use Dhc.DataCase, async: false

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.StripeSync

  import Ecto.Query

  @price_id "price_membership_regression"
  @customer_id "cus_last_payment_regression"

  describe "run_sync/1 last payment date" do
    setup do
      bypass = Bypass.open()
      original_url = Application.get_env(:dhc, :stripe_api_url)
      original_key = Application.get_env(:dhc, :stripe_secret_key)

      Application.put_env(:dhc, :stripe_api_url, "http://localhost:#{bypass.port}")
      Application.put_env(:dhc, :stripe_secret_key, "sk_test_last_payment")

      # Fresh price cache so run_sync uses our fake price id without hitting /v1/prices.
      :ok = Dhc.StripeSync.Repository.upsert_price_id_cache(@price_id)

      on_exit(fn ->
        Application.put_env(:dhc, :stripe_api_url, original_url)
        Application.put_env(:dhc, :stripe_secret_key, original_key)
      end)

      %{bypass: bypass}
    end

    test "stores the latest invoice paid_at for an active member, not start_date", %{
      bypass: bypass
    } do
      fixture = Dhc.MemberFixtures.member_fixture(customer_id: @customer_id, is_active: true)

      start_date = DateTime.utc_now() |> DateTime.add(-365, :day) |> DateTime.truncate(:second)
      paid_at = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)

      Bypass.expect(bypass, "GET", "/v1/subscriptions", fn conn ->
        params = URI.decode_query(conn.query_string)

        expanded? = Map.get(params, "expand[]") == "data.latest_invoice"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [subscription_payload(expanded?, start_date, paid_at)],
            "has_more" => false
          })
        )
      end)

      assert {:ok, summary} = StripeSync.run_sync([@customer_id])
      assert summary.active == 1

      member =
        Repo.one!(from(mp in MemberProfile, where: mp.user_profile_id == ^fixture.profile_id))

      assert member.last_payment_date == paid_at,
             "expected last_payment_date to be the recent invoice paid_at " <>
               "#{DateTime.to_iso8601(paid_at)}, got #{inspect(member.last_payment_date)}"
    end

    defp subscription_payload(expanded?, start_date, paid_at) do
      base = %{
        "id" => "sub_regression_1",
        "object" => "subscription",
        "customer" => @customer_id,
        "status" => "active",
        "created" => DateTime.to_unix(start_date),
        "start_date" => DateTime.to_unix(start_date),
        "ended_at" => nil,
        "pause_collection" => nil,
        "latest_invoice" => "in_recent",
        "items" => %{
          "object" => "list",
          "data" => [
            %{"id" => "si_1", "object" => "subscription_item", "price" => %{"id" => @price_id}}
          ]
        }
      }

      if expanded? do
        put_in(
          base["latest_invoice"],
          %{
            "id" => "in_recent",
            "object" => "invoice",
            "status_transitions" => %{"paid_at" => DateTime.to_unix(paid_at)}
          }
        )
      else
        base
      end
    end
  end
end
