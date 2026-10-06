defmodule Dhc.StripeSyncTest do
  use ExUnit.Case, async: true

  alias Dhc.StripeHTTPStub
  alias Dhc.StripeSync

  describe "resolve_last_payment_date/1" do
    test "uses paid_at from latest_invoice status_transitions when available" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => %{
          "status_transitions" => %{
            "paid_at" => 1_710_000_000
          }
        }
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert %DateTime{} = result
      assert result == DateTime.from_unix!(1_710_000_000)
    end

    test "falls back to start_date when paid_at is nil" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => %{
          "status_transitions" => %{
            "paid_at" => nil
          }
        }
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert %DateTime{} = result
      assert result == DateTime.from_unix!(1_700_000_000)
    end

    test "falls back to start_date when latest_invoice is nil" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => nil
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert %DateTime{} = result
      assert result == DateTime.from_unix!(1_700_000_000)
    end

    test "returns nil when both paid_at and start_date are nil" do
      subscription = %{
        "status" => "active",
        "start_date" => nil,
        "latest_invoice" => nil
      }

      assert StripeSync.resolve_last_payment_date(subscription) == nil
    end

    test "returns nil when latest_invoice is a string (not expanded)" do
      subscription = %{
        "status" => "active",
        "start_date" => nil,
        "latest_invoice" => "in_12345"
      }

      # String latest_invoice → safe_get_in returns nil → falls through to nil start_date → nil
      assert StripeSync.resolve_last_payment_date(subscription) == nil
    end

    test "falls back to start_date when latest_invoice is a string" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => "in_12345"
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert result == DateTime.from_unix!(1_700_000_000)
    end
  end

  describe "get_target_customer_ids/1" do
    test "deduplicates and trims manually provided customer IDs" do
      ids = [" cus_abc ", "cus_def", "cus_abc", "", "  "]

      result = StripeSync.get_target_customer_ids(ids)

      assert result == ["cus_abc", "cus_def"]
    end

    test "returns deduplicated list preserving order" do
      ids = ["cus_a", "cus_b", "cus_a"]

      result = StripeSync.get_target_customer_ids(ids)

      assert result == ["cus_a", "cus_b"]
    end

    test "filters out empty strings after trimming" do
      ids = ["cus_a", "  ", "", "cus_b"]

      result = StripeSync.get_target_customer_ids(ids)

      assert result == ["cus_a", "cus_b"]
    end
  end

  describe "list_subscriptions/2" do
    test "lists one page of subscriptions on the price through the Stripe client" do
      StripeHTTPStub.expect("GET", "/v1/subscriptions", fn conn ->
        assert StripeHTTPStub.header(conn, "stripe-version") == "2025-10-29.clover"

        assert StripeHTTPStub.query(conn) == %{
                 "status" => "all",
                 "price" => "price_abc",
                 "limit" => "100",
                 "expand[]" => "data.latest_invoice"
               }

        StripeHTTPStub.json(conn, %{
          "object" => "list",
          "data" => [
            %{
              "id" => "sub_123",
              "customer" => "cus_abc",
              "created" => 1_710_000_000,
              "status" => "active"
            }
          ],
          "has_more" => false
        })
      end)

      assert {:ok, %{"data" => [%{"id" => "sub_123"}]}} =
               StripeSync.list_subscriptions("price_abc")
    end

    test "passes the pagination cursor" do
      StripeHTTPStub.expect("GET", "/v1/subscriptions", fn conn ->
        assert StripeHTTPStub.query(conn)["starting_after"] == "sub_99"
        StripeHTTPStub.json(conn, %{"object" => "list", "data" => [], "has_more" => false})
      end)

      assert {:ok, %{"data" => []}} = StripeSync.list_subscriptions("price_abc", "sub_99")
    end

    test "returns the Stripe error body on a non-2xx answer" do
      StripeHTTPStub.expect("GET", "/v1/subscriptions", fn conn ->
        StripeHTTPStub.json(conn, 401, %{"error" => %{"message" => "Invalid API key"}})
      end)

      assert {:error, {:stripe_api, 401, %{"error" => %{"message" => "Invalid API key"}}}} =
               StripeSync.list_subscriptions("price_abc")
    end

    test "returns a transport failure as an HTTP error" do
      StripeHTTPStub.expect("GET", "/v1/subscriptions", fn conn ->
        StripeHTTPStub.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:http_error, %Req.TransportError{reason: :econnrefused}}} =
               StripeSync.list_subscriptions("price_abc")
    end
  end

  describe "fetch_latest_subscriptions/2" do
    test "pages through every subscription and keeps only target customers" do
      test_pid = self()

      StripeHTTPStub.stub("GET", "/v1/subscriptions", fn conn ->
        cursor = StripeHTTPStub.query(conn)["starting_after"]
        send(test_pid, {:page_requested, cursor})

        case cursor do
          nil ->
            StripeHTTPStub.json(conn, %{
              "data" => [
                %{"id" => "sub_1", "customer" => "cus_target"},
                %{"id" => "sub_2", "customer" => "cus_other"}
              ],
              "has_more" => true
            })

          "sub_2" ->
            StripeHTTPStub.json(conn, %{
              "data" => [%{"id" => "sub_3", "customer" => %{"id" => "cus_target"}}],
              "has_more" => false
            })
        end
      end)

      assert {:ok, %{scanned: 3, subscriptions: %{"cus_target" => subscriptions}}} =
               StripeSync.fetch_latest_subscriptions(["price_abc"], MapSet.new(["cus_target"]))

      assert Enum.map(subscriptions, & &1["id"]) == ["sub_3", "sub_1"]
      assert_received {:page_requested, nil}
      assert_received {:page_requested, "sub_2"}
    end

    test "stops at the first Stripe failure and keeps its body" do
      StripeHTTPStub.expect("GET", "/v1/subscriptions", fn conn ->
        StripeHTTPStub.json(conn, 500, %{"error" => %{"type" => "api_error"}})
      end)

      assert {:error, {:stripe_api, 500, %{"error" => %{"type" => "api_error"}}}} =
               StripeSync.fetch_latest_subscriptions(
                 ["price_abc", "price_def"],
                 MapSet.new(["cus_target"])
               )
    end
  end

  describe "list_membership_prices/0" do
    test "lists the active prices for every membership lookup key" do
      StripeHTTPStub.expect("GET", "/v1/prices", fn conn ->
        assert StripeHTTPStub.header(conn, "stripe-version") == "2025-10-29.clover"

        assert StripeHTTPStub.query_pairs(conn) |> Enum.sort() ==
                 Enum.sort(
                   [{"active", "true"}, {"limit", "10"}] ++
                     Enum.map(Dhc.Stripe.LookupKeys.all(), &{"lookup_keys[]", &1})
                 )

        StripeHTTPStub.json(conn, %{
          "object" => "list",
          "data" => [%{"id" => "price_abc123", "lookup_key" => "standard_membership_fee"}]
        })
      end)

      assert {:ok, [%{"id" => "price_abc123"}]} = StripeSync.list_membership_prices()
    end

    test "returns the Stripe error body on a non-2xx answer" do
      StripeHTTPStub.expect("GET", "/v1/prices", fn conn ->
        StripeHTTPStub.json(conn, 403, %{"error" => %{"message" => "Forbidden"}})
      end)

      assert {:error, {:stripe_api, 403, %{"error" => %{"message" => "Forbidden"}}}} =
               StripeSync.list_membership_prices()
    end
  end
end

defmodule Dhc.StripeSync.RepositoryMarkCustomerActiveTest do
  @moduledoc """
  ALE-193: `mark_customer_active/3` must apply its two `update_all`s
  atomically so a partial failure self-heals via sync retry.

  These tests run in the default (non-integration) CI gate — the existing
  `RepositoryIntegrationTest` is tagged `:integration` and excluded from the
  default `mise run phx-test` run. The happy path here verifies both the
  member-profile date update and the user-profile `is_active` flip land
  together, and the atomicity test verifies that a failure of the second
  update rolls the first back (so a retry sees a clean state).
  """

  use Dhc.DataCase, async: false

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.StripeSync.Repository
  alias Dhc.UserProfiles.UserProfile

  import Ecto.Query

  describe "mark_customer_active/3" do
    test "applies both the member-profile date update and the is_active flip together" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: false)
      last_payment_date = DateTime.utc_now() |> DateTime.truncate(:second)

      assert :ok =
               Repository.mark_customer_active(fixture.customer_id, last_payment_date, nil)

      member =
        Repo.one!(from(mp in MemberProfile, where: mp.user_profile_id == ^fixture.profile_id))

      assert member.last_payment_date == last_payment_date
      assert is_nil(member.subscription_paused_until)
      assert is_nil(member.membership_end_date)

      profile = Repo.get!(UserProfile, fixture.profile_id)
      assert profile.is_active == true
    end

    test "rolls back the first update when the second one fails, so a retry sees clean state" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: false)
      last_payment_date = DateTime.utc_now() |> DateTime.truncate(:second)

      # Pin a CHECK that forbids is_active = true for this customer's
      # profile, so the second update_all (the is_active flip) raises a
      # check_violation. If mark_customer_active wraps both updates in a
      # single transaction, the first update (the member-profile date
      # change) rolls back too, leaving the member profile unchanged for a
      # retry. Without the wrap the first update would persist.
      #
      # The customer_id is a fixture-generated Stripe-style string, safe to
      # inline (DDL does not support bind parameters). The constraint is
      # dropped in on_exit so it never leaks into other tests sharing the
      # sandbox transaction (DDL CONSTRAINTs are not transactional).
      escaped = String.replace(fixture.customer_id, "'", "''")

      constraint = "is_active_must_stay_false_#{System.unique_integer([:positive])}"

      Repo.query!(
        "ALTER TABLE user_profiles ADD CONSTRAINT #{constraint} " <>
          "CHECK (customer_id IS DISTINCT FROM '#{escaped}' OR " <>
          "is_active IS DISTINCT FROM true)"
      )

      on_exit(fn ->
        Repo.query!("ALTER TABLE user_profiles DROP CONSTRAINT IF EXISTS #{constraint}")
      end)

      result = Repository.mark_customer_active(fixture.customer_id, last_payment_date, nil)

      # The transaction aborted; the function surfaces the failure.
      assert match?({:error, _}, result)

      # Member-profile date update must have rolled back with the failed
      # is_active flip — a retry sees the original (unchanged, nil) state.
      member =
        Repo.one!(from(mp in MemberProfile, where: mp.user_profile_id == ^fixture.profile_id))

      assert member.last_payment_date == nil
      assert member.subscription_paused_until == nil
    end
  end

  describe "mark_customer_inactive/1" do
    test "revokes the customer's existing Sessions with access" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: true)
      principal = Dhc.AuthFixtures.principal_fixture(id: fixture.auth_user_id)
      token = Dhc.AuthFixtures.session_token(principal)

      assert {:ok, 1} = Repository.mark_customer_inactive(fixture.customer_id)

      assert {:error, :invalid} = Dhc.Auth.get_principal_by_session_token(token)

      profile = Repo.get!(Dhc.UserProfiles.UserProfile, fixture.profile_id)
      assert profile.is_active == false
    end
  end
end

defmodule Dhc.StripeSync.RepositoryIntegrationTest do
  @moduledoc """
  Integration test for Dhc.StripeSync.Repository against the test database.

  Reproduces the Ecto.Query.CastError that occurs when `user_profile_ids_for_customer/1`
  queries `"user_profiles"` without a schema (returning raw binary UUIDs) and passes
  them to a schema query expecting `:binary_id` (UUID strings).
  """

  use Dhc.DataCase, async: false

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.StripeSync.Repository

  import Ecto.Query

  @moduletag :integration

  describe "mark_customer_active/3" do
    test "updates member profile without CastError when user_profile_id is a UUID" do
      fixture = Dhc.MemberFixtures.member_fixture()

      last_payment_date = DateTime.utc_now() |> DateTime.truncate(:second)

      # This call exercises user_profile_ids_for_customer/1 -> update_member_profiles/2
      assert :ok =
               Repository.mark_customer_active(
                 fixture.customer_id,
                 last_payment_date,
                 nil
               )

      member =
        Repo.one!(
          from(mp in MemberProfile,
            where: mp.user_profile_id == ^fixture.profile_id
          )
        )

      assert member.last_payment_date == last_payment_date
      assert is_nil(member.subscription_paused_until)
      assert is_nil(member.membership_end_date)
    end
  end

  describe "mark_customer_paused/2" do
    test "updates member profile without CastError when user_profile_id is a UUID" do
      fixture = Dhc.MemberFixtures.member_fixture()
      resume_date = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      assert :ok = Repository.mark_customer_paused(fixture.customer_id, resume_date)

      member =
        Repo.one!(
          from(mp in MemberProfile,
            where: mp.user_profile_id == ^fixture.profile_id
          )
        )

      assert member.subscription_paused_until == resume_date
    end
  end
end
