defmodule Dhc.OnboardingTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.Invitations.Invitation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.Workers.AcceptanceRecoveryWorker

  setup do
    original_adapter = Application.get_env(:dhc, :onboarding_stripe_adapter)
    original_result = Application.get_env(:dhc, :onboarding_stripe_result)
    original_customer_result = Application.get_env(:dhc, :onboarding_stripe_customer_result)
    original_cancel_result = Application.get_env(:dhc, :onboarding_stripe_cancel_result)
    original_progress = Application.get_env(:dhc, :onboarding_stripe_progress)

    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.OnboardingTestStripeAdapter)
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
    Application.put_env(:dhc, :onboarding_test_pid, self())

    on_exit(fn ->
      Application.put_env(:dhc, :onboarding_stripe_adapter, original_adapter)

      if original_result do
        Application.put_env(:dhc, :onboarding_stripe_result, original_result)
      else
        Application.delete_env(:dhc, :onboarding_stripe_result)
      end

      if original_customer_result do
        Application.put_env(:dhc, :onboarding_stripe_customer_result, original_customer_result)
      else
        Application.delete_env(:dhc, :onboarding_stripe_customer_result)
      end

      if original_cancel_result do
        Application.put_env(:dhc, :onboarding_stripe_cancel_result, original_cancel_result)
      else
        Application.delete_env(:dhc, :onboarding_stripe_cancel_result)
      end

      if original_progress do
        Application.put_env(:dhc, :onboarding_stripe_progress, original_progress)
      else
        Application.delete_env(:dhc, :onboarding_stripe_progress)
      end

      Application.delete_env(:dhc, :onboarding_test_pid)
    end)
  end

  test "acceptance provisions Membership before atomically creating the Member" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)

    assert {:ok, %{member_id: member_id}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_success"
             })

    assert member_id == invitation.prospective_principal_id
    assert Repo.get!(Invitation, invitation.id).status == "accepted"
    assert %Principal{} = Repo.get!(Principal, member_id)

    assert %MemberProfile{membership_start_date: %DateTime{}} =
             Repo.get!(MemberProfile, member_id)

    assert %InvitationAcceptanceAttempt{
             status: "completed",
             stripe_customer_id: "cus_onboarding",
             stripe_state: %{
               "setup_intent_id" => "seti_onboarding",
               "monthly_subscription_id" => "sub_monthly_onboarding"
             }
           } = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    assert_received {:create_customer, _}
    assert_received {:provision_membership, %{confirmation_token: "ctok_success"}}
  end

  test "pricing is read-only and uses the shared Stripe adapter" do
    invitation = insert_invitation!()

    assert {:ok, %{proratedPrice: %{amount: 0}}} =
             Onboarding.pricing(invitation.id, "WELCOME")

    assert_received {:preview_membership, "WELCOME"}
    assert Repo.get!(Invitation, invitation.id).stripe_customer_id == nil

    refute Repo.exists?(
             from(a in InvitationAcceptanceAttempt, where: a.invitation_id == ^invitation.id)
           )
  end

  test "an annual decline cancels partial Membership provisioning before a retry" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)
    decline = {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, decline})

    Application.put_env(:dhc, :onboarding_stripe_progress, %{
      "monthly_subscription_id" => "sub_monthly_onboarding",
      "monthly_confirmed" => true,
      "annual_subscription_id" => "sub_annual_onboarding"
    })

    attrs = %{confirmation_token: "ctok_declined"}

    assert {:error, {:payment_failed, ^decline}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", attrs)

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert attempt.status == "declined"
    assert attempt.stripe_customer_id == "cus_onboarding"

    assert_received {:cancel_membership,
                     %{
                       "monthly_subscription_id" => "sub_monthly_onboarding",
                       "monthly_confirmed" => true,
                       "annual_subscription_id" => "sub_annual_onboarding"
                     }}

    assert Repo.get!(Invitation, invitation.id).status == "pending"
    refute Repo.get(Principal, invitation.prospective_principal_id)

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", attrs)

    attempts =
      from(a in InvitationAcceptanceAttempt,
        where: a.invitation_id == ^invitation.id,
        order_by: [asc: a.created_at]
      )
      |> Repo.all()

    assert attempts |> Enum.map(& &1.status) |> Enum.sort() == ["completed", "declined"]
    assert Enum.map(attempts, & &1.stripe_customer_id) == ["cus_onboarding", "cus_onboarding"]
  end

  test "a permanent payment error concludes the attempt so corrected payment data can be used" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)
    failure = {:setup_intent_failed, "requires_payment_method"}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, failure})

    assert {:error, {:payment_failed, ^failure}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_invalid"
             })

    assert %InvitationAcceptanceAttempt{status: "declined"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_corrected"
             })

    assert_received {:provision_membership, %{confirmation_token: "ctok_corrected"}}

    assert 2 ==
             Repo.aggregate(
               from(a in InvitationAcceptanceAttempt, where: a.invitation_id == ^invitation.id),
               :count
             )
  end

  test "failed subscription cleanup is retried before the attempt is concluded" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)
    decline = {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, decline})
    Application.put_env(:dhc, :onboarding_stripe_cancel_result, {:error, :stripe_unavailable})

    assert {:error, {:payment_failed, ^decline}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_declined"
             })

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert attempt.status == "cleanup_pending"
    assert_enqueued(worker: AcceptanceRecoveryWorker, args: %{"attempt_id" => attempt.id})

    assert {:error, :payment_cleanup_pending} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_corrected"
             })

    refute_received {:provision_membership, %{confirmation_token: "ctok_corrected"}}

    assert {:snooze, 60} =
             perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})

    Application.put_env(:dhc, :onboarding_stripe_cancel_result, :ok)

    assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
    assert Repo.get!(InvitationAcceptanceAttempt, attempt.id).status == "declined"
  end

  test "an active attempt keeps its original Stripe parameters across transport retries" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})

    original_attrs = %{
      confirmation_token: "ctok_original",
      coupon_code: "WELCOME",
      mandate_context: %{ip_address: "127.0.0.1", user_agent: "first-agent"}
    }

    assert {:error, {:payment_failed, {:http_error, :timeout}}} =
             Onboarding.accept(
               invitation.id,
               token,
               "Next of Kin",
               "+353810000001",
               original_attrs
             )

    assert_received {:provision_membership, %{confirmation_token: "ctok_original"}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(
               invitation.id,
               token,
               "Updated Kin",
               "+353810000002",
               %{
                 confirmation_token: "ctok_changed",
                 coupon_code: "CHANGED",
                 mandate_context: %{ip_address: "127.0.0.2", user_agent: "second-agent"}
               }
             )

    assert_received {:provision_membership,
                     %{
                       confirmation_token: "ctok_original",
                       coupon_code: "WELCOME",
                       mandate_context: %{
                         ip_address: "127.0.0.1",
                         user_agent: "first-agent"
                       }
                     }}

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert attempt.status == "completed"
    assert attempt.acceptance_data["next_of_kin_name"] == "Updated Kin"
    assert attempt.acceptance_data["payment"]["confirmation_token"] == "ctok_original"
  end

  test "a live-shaped Stripe customer rejection closes the attempt" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)
    decline = {:stripe_customer, {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}}
    Application.put_env(:dhc, :onboarding_stripe_customer_result, {:error, decline})

    assert {:error, {:payment_failed, ^decline}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_declined"
             })

    assert %InvitationAcceptanceAttempt{status: "declined", concluded_at: %DateTime{}} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
  end

  test "a Stripe rate limit keeps the active attempt available for retry" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)
    rate_limit = {:stripe_api, 429, %{"error" => %{"code" => "rate_limit"}}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, rate_limit})

    attrs = %{confirmation_token: "ctok_retry"}

    assert {:error, {:payment_failed, ^rate_limit}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", attrs)

    assert %InvitationAcceptanceAttempt{status: "processing", concluded_at: nil} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", attrs)

    assert 1 ==
             Repo.aggregate(
               from(a in InvitationAcceptanceAttempt, where: a.invitation_id == ^invitation.id),
               :count
             )
  end

  test "an active attempt can be reverified and resumed after the Invitation expires" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})

    attrs = %{confirmation_token: "ctok_before_expiry"}

    assert {:error, {:payment_failed, {:http_error, :timeout}}} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", attrs)

    invitation
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert {:ok, resumed_token} =
             Onboarding.verify_credentials(
               invitation.id,
               invitation.email,
               invitation.date_of_birth
             )

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(
               invitation.id,
               resumed_token,
               "Next of Kin",
               "+353810000001",
               attrs
             )

    assert %InvitationAcceptanceAttempt{status: "completed"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
  end

  test "a provisioned attempt is recoverable after local conversion rolls back" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)

    Application.put_env(:dhc, :onboarding_stripe_result, fn ->
      conflicting_principal =
        %Principal{id: Ecto.UUID.generate(), email: invitation.email}
        |> Repo.insert!()

      send(self(), {:conflicting_principal, conflicting_principal})
      {:ok, %{}}
    end)

    assert {:error, :principal_creation_failed} =
             Onboarding.accept(
               invitation.id,
               token,
               "Next of Kin",
               "+353810000001",
               %{confirmation_token: "ctok_recovery"}
             )

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert attempt.status == "provisioned"
    assert Repo.get!(Invitation, invitation.id).status == "pending"
    assert_enqueued(worker: AcceptanceRecoveryWorker, args: %{"attempt_id" => attempt.id})

    assert_received {:conflicting_principal, conflicting_principal}
    Repo.delete!(conflicting_principal)
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    invitation
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert :ok =
             perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})

    assert Repo.get!(Invitation, invitation.id).status == "accepted"
    assert Repo.get!(InvitationAcceptanceAttempt, attempt.id).status == "completed"
  end

  test "an invitation for an existing Principal is rejected before Stripe work" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)

    %Principal{id: Ecto.UUID.generate(), email: invitation.email}
    |> Repo.insert!()

    assert {:error, :invalid_invitation} =
             Onboarding.accept(
               invitation.id,
               token,
               "Next of Kin",
               "+353810000001",
               %{confirmation_token: "ctok_must_not_be_used"}
             )

    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}
    refute Repo.get_by(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert Repo.get!(Invitation, invitation.id).status == "pending"
  end

  defp insert_invitation! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Invitation{
      email: "onboarding-#{System.unique_integer([:positive])}@example.com",
      prospective_principal_id: Ecto.UUID.generate(),
      status: "pending",
      expires_at: DateTime.add(now, 7, :day),
      invitation_type: "member",
      first_name: "Ada",
      last_name: "Lovelace",
      phone_number: "+353810000000",
      date_of_birth: ~D[1990-01-01]
    }
    |> Repo.insert!()
  end

  defp token_for(invitation) do
    Onboarding.issue_verification_token(
      invitation.id,
      invitation.email,
      invitation.date_of_birth
    )
  end
end
