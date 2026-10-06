defmodule Dhc.MembersCustomerEchoTest do
  @moduledoc """
  `Dhc.Members.update_member/2` echoes name and phone changes to the member's
  Stripe customer through `Dhc.Stripe.Operations` (ALE-342), best-effort:
  a Stripe failure is logged and never fails the database update.
  """

  use Dhc.DataCase, async: true

  alias Dhc.Members
  alias Dhc.StripeHTTPStub

  @moduletag :capture_log

  test "echoes a name and phone change to the Stripe customer" do
    member = member_with_customer("cus_echo")

    StripeHTTPStub.expect("POST", "/v1/customers/cus_echo", fn conn ->
      assert StripeHTTPStub.form(conn) == %{"name" => "Ada Lovelace", "phone" => "+353870000001"}
      StripeHTTPStub.json(conn, %{"id" => "cus_echo"})
    end)

    assert {:ok, %{first_name: "Ada", last_name: "Lovelace"}} =
             Members.update_member(member.principal_id, %{
               "firstName" => "Ada",
               "lastName" => "Lovelace",
               "phoneNumber" => "+353870000001"
             })
  end

  test "keeps the database update when Stripe rejects the echo" do
    member = member_with_customer("cus_echo_down")

    StripeHTTPStub.expect("POST", "/v1/customers/cus_echo_down", fn conn ->
      StripeHTTPStub.stripe_error(conn, 500, %{"message" => "boom"})
    end)

    assert {:ok, %{first_name: "Grace"}} =
             Members.update_member(member.principal_id, %{"firstName" => "Grace"})
  end

  test "does not call Stripe when nothing Stripe holds changed" do
    member = member_with_customer("cus_echo_untouched")

    assert {:ok, _member} =
             Members.update_member(member.principal_id, %{"nextOfKinName" => "Someone"})
  end

  defp member_with_customer(customer_id) do
    Dhc.MemberFixtures.member_fixture(
      customer_id: customer_id,
      first_name: "Test",
      last_name: "Member"
    )
  end
end
