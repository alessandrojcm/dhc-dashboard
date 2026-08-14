defmodule Dhc.OnboardingTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query

  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.Principal
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Auth.UserRole
  alias Dhc.Invitations.Invitation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Onboarding.Workers.AcceptanceRecoveryWorker
  alias Dhc.Onboarding.Workers.DiscordContinuationExpiryWorker
  alias Dhc.StripeWebhooks
  alias Dhc.UserProfiles.UserProfile

  setup do
    original_adapter = Application.get_env(:dhc, :onboarding_stripe_adapter)
    original_result = Application.get_env(:dhc, :onboarding_stripe_result)
    original_customer_result = Application.get_env(:dhc, :onboarding_stripe_customer_result)
    original_cancel_result = Application.get_env(:dhc, :onboarding_stripe_cancel_result)
    original_progress = Application.get_env(:dhc, :onboarding_stripe_progress)
    original_expiry_clock = Application.get_env(:dhc, :onboarding_discord_expiry_clock)

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

      if original_expiry_clock do
        Application.put_env(:dhc, :onboarding_discord_expiry_clock, original_expiry_clock)
      else
        Application.delete_env(:dhc, :onboarding_discord_expiry_clock)
      end
    end)
  end

  test "acceptance provisions Membership before atomically creating the Member" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)

    assert {:ok, %{member_id: member_id}} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
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

    assert %ExternalIdentity{
             principal_id: ^member_id,
             provider: "discord"
           } = Repo.get_by!(ExternalIdentity, principal_id: member_id)

    continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, continuation_id)
    assert continuation.status == "consumed"
    assert continuation.provider_subject == nil
    assert continuation.display_metadata == %{}
    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
  end

  test "a legacy invitation verification token cannot begin Stripe work" do
    invitation = insert_invitation!()
    {:ok, token} = token_for(invitation)

    assert {:error, :discord_verification_required} =
             Onboarding.accept(invitation.id, token, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_must_not_be_used"
             })

    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}
    refute Repo.exists?(InvitationAcceptanceAttempt)
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

  test "credential verification starts one protected pre-payment attempt and continuation" do
    invitation = insert_invitation!()

    assert {:ok, first} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    assert first.view.state == "awaiting_oauth"
    continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, first.continuation_id)
    assert {:ok, refreshed} = Onboarding.acceptance_state(first.continuation_id)
    assert refreshed.state == "awaiting_oauth"

    assert {:error, :missing_browser_proof} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    assert {:ok, replay} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth),
               first.continuation_id
             )

    assert Repo.get!(InvitationAcceptanceDiscordContinuation, replay.continuation_id).attempt_id ==
             continuation.attempt_id

    assert replay.continuation_id == first.continuation_id
    assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    assert Repo.aggregate(InvitationAcceptanceDiscordContinuation, :count) == 1
    refute Repo.get(Principal, invitation.prospective_principal_id)
    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}
  end

  test "expiry maintenance closes an unconsumed Discord proof and allows a fresh attempt" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    assert {:ok, %{state: "discordVerified"}} =
             Onboarding.verify_discord(started.continuation_id, %{
               "sub" => "expired-discord-subject",
               "preferred_username" => "expired-member"
             })

    started.continuation_id
    |> then(&Repo.get!(InvitationAcceptanceDiscordContinuation, &1))
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert :ok = perform_job(DiscordContinuationExpiryWorker, %{})

    assert %InvitationAcceptanceDiscordContinuation{
             status: "expired",
             provider_subject: nil,
             display_metadata: %{}
           } = Repo.get!(InvitationAcceptanceDiscordContinuation, started.continuation_id)

    assert %InvitationAcceptanceAttempt{status: "declined"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)

    assert {:ok, fresh} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    refute fresh.continuation_id == started.continuation_id
    assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 2
  end

  test "expiry maintenance preserves a consumed proof while payment remains recoverable" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    assert {:ok, %{state: "discordVerified"}} =
             Onboarding.verify_discord(started.continuation_id, %{
               "sub" => "recoverable-expired-subject",
               "preferred_username" => "recoverable-member"
             })

    Application.put_env(
      :dhc,
      :onboarding_stripe_result,
      {:error, {:http_error, :timeout}}
    )

    assert {:ok, %{state: "paymentReady"}} =
             Onboarding.continue_acceptance(started.continuation_id)

    assert {:error, {:provider_unavailable, {:http_error, :timeout}}} =
             Onboarding.submit_payment(started.continuation_id, %{
               next_of_kin_name: "Grace Hopper",
               next_of_kin_phone: "+353810000099",
               confirmation_token: "ctok_recoverable_expiry",
               coupon_code: nil
             })

    started.continuation_id
    |> then(&Repo.get!(InvitationAcceptanceDiscordContinuation, &1))
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert :ok = perform_job(DiscordContinuationExpiryWorker, %{})

    assert %InvitationAcceptanceDiscordContinuation{
             status: "verified",
             provider_subject: "recoverable-expired-subject"
           } = Repo.get!(InvitationAcceptanceDiscordContinuation, started.continuation_id)

    assert %InvitationAcceptanceAttempt{status: "payment_pending"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    assert Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
  end

  test "expiry maintenance reports inconsistent Claims without deleting evidence" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    assert {:ok, %{state: "discordVerified"}} =
             Onboarding.verify_discord(started.continuation_id, %{
               "sub" => "inconsistent-expiry-subject"
             })

    started.continuation_id
    |> then(&Repo.get!(InvitationAcceptanceDiscordContinuation, &1))
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    claim = Repo.one!(InvitationAcceptanceDiscordSubjectClaim)

    claim
    |> Ecto.Changeset.change(provider_subject: "mismatched-expiry-subject")
    |> Repo.update!()

    assert {:error, {:inconsistent_claims, [continuation_id]}} =
             DiscordContinuationExpiryWorker.perform(%Oban.Job{args: %{}})

    assert continuation_id == started.continuation_id

    assert Repo.get!(InvitationAcceptanceDiscordContinuation, started.continuation_id).status ==
             "verified"

    assert Repo.get!(InvitationAcceptanceDiscordSubjectClaim, claim.id)
  end

  test "expiry maintenance enqueues uniquely without sensitive arguments" do
    assert {:ok, _job} = Oban.insert(DiscordContinuationExpiryWorker.new(%{}))
    assert {:ok, _same_job} = Oban.insert(DiscordContinuationExpiryWorker.new(%{}))

    assert [%{args: args}] = all_enqueued(worker: DiscordContinuationExpiryWorker)
    assert args == %{}
  end

  test "acceptance recovery enqueues uniquely with only the Attempt identifier" do
    attempt_id = Ecto.UUID.generate()
    args = %{"attempt_id" => attempt_id}

    assert {:ok, _job} = Oban.insert(AcceptanceRecoveryWorker.new(args))
    assert {:ok, _same_job} = Oban.insert(AcceptanceRecoveryWorker.new(args))

    assert [%{args: ^args}] = all_enqueued(worker: AcceptanceRecoveryWorker)
  end

  test "Stripe reconciliation advances a unique scheduled recovery" do
    original_delay = Application.get_env(:dhc, :acceptance_recovery_delay_seconds)
    Application.put_env(:dhc, :acceptance_recovery_delay_seconds, 1)

    on_exit(fn ->
      if is_nil(original_delay) do
        Application.delete_env(:dhc, :acceptance_recovery_delay_seconds)
      else
        Application.put_env(:dhc, :acceptance_recovery_delay_seconds, original_delay)
      end
    end)

    invitation = insert_invitation!()

    assert {:ok, _started} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    attempt =
      invitation.id
      |> then(&Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: &1))
      |> Ecto.Changeset.change(
        status: "payment_pending",
        stripe_customer_id: "cus_reconcile_scheduled"
      )
      |> Repo.update!()

    args = %{"attempt_id" => attempt.id}

    assert {:ok, original_job} =
             args
             |> AcceptanceRecoveryWorker.new(schedule_in: 30)
             |> Oban.insert()

    assert :ok = Onboarding.reconcile_stripe_event(%{"customer" => attempt.stripe_customer_id})

    assert [%{id: job_id, scheduled_at: scheduled_at}] =
             all_enqueued(worker: AcceptanceRecoveryWorker, args: args)

    assert job_id == original_job.id
    assert DateTime.before?(scheduled_at, original_job.scheduled_at)
  end

  test "verified Continue is single-use and atomically finalizes the paid Discord-bound Member" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    assert {:ok, %{state: "discordVerified"}} =
             Onboarding.verify_discord(started.continuation_id, %{
               "sub" => "paid-discord-subject",
               "preferred_username" => "paid-member",
               "picture" => "https://cdn.example.com/paid-member.png"
             })

    attrs = %{
      next_of_kin_name: "Grace Hopper",
      next_of_kin_phone: "+353810000099",
      confirmation_token: "ctok_discord_paid",
      coupon_code: nil,
      mandate_context: %{ip_address: "127.0.0.1", user_agent: "test-agent"}
    }

    invitation_email = invitation.email

    assert {:ok, %{state: "paymentReady"}} =
             Onboarding.continue_acceptance(started.continuation_id)

    assert {:error, :invalid_continuation} =
             Onboarding.cancel_discord(started.continuation_id)

    assert Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
    refute_received {:prepare_payment, _}
    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}

    assert {:ok, %{state: "accepted", invitation_email: ^invitation_email}} =
             Onboarding.submit_payment(started.continuation_id, attrs)

    assert_received {:prepare_payment, nil}
    assert_received {:create_customer, %{attempt_id: attempt_id}}

    assert_received {:provision_membership,
                     %{
                       confirmation_token: "ctok_discord_paid",
                       mandate_context: %{ip_address: "127.0.0.1", user_agent: "test-agent"}
                     }}

    assert {:ok, %{state: "accepted"}} =
             Onboarding.submit_payment(started.continuation_id, %{
               attrs
               | next_of_kin_name: "Must not replace durable input",
                 confirmation_token: "ctok_must_not_be_used"
             })

    refute_received {:prepare_payment, _}
    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}
    assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    assert Repo.aggregate(InvitationAcceptanceDiscordSubjectClaim, :count) == 0

    principal_id = invitation.prospective_principal_id
    assert %Principal{id: ^principal_id, email: email} = Repo.get!(Principal, principal_id)
    assert email == invitation.email

    assert %UserProfile{principal_id: ^principal_id, customer_id: "cus_onboarding"} =
             Repo.get_by!(UserProfile, principal_id: principal_id)

    assert %MemberProfile{id: ^principal_id, next_of_kin_name: "Grace Hopper"} =
             Repo.get!(MemberProfile, principal_id)

    assert %UserRole{role: "member"} = Repo.get_by!(UserRole, principal_id: principal_id)

    assert %ExternalIdentity{
             principal_id: ^principal_id,
             provider: "discord",
             provider_subject: "paid-discord-subject",
             metadata: %{"username" => "paid-member"}
           } = Repo.get_by!(ExternalIdentity, principal_id: principal_id, provider: "discord")

    assert %InvitationAcceptanceAttempt{id: ^attempt_id, status: "completed"} =
             Repo.get!(InvitationAcceptanceAttempt, attempt_id)

    assert %InvitationAcceptanceDiscordContinuation{
             status: "consumed",
             provider_subject: nil,
             display_metadata: %{}
           } = Repo.get!(InvitationAcceptanceDiscordContinuation, started.continuation_id)

    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
    refute Repo.exists?(PrincipalToken)
  end

  test "complimentary acceptance uses the same finalization without a payment descriptor" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _state} =
      Onboarding.verify_discord(started.continuation_id, %{
        "sub" => "complimentary-discord-subject",
        "preferred_username" => "complimentary-member"
      })

    assert {:ok, %{state: "paymentReady"}} =
             Onboarding.continue_acceptance(started.continuation_id)

    assert {:ok, %{state: "accepted"}} =
             Onboarding.submit_payment(started.continuation_id, %{
               next_of_kin_name: "Grace Hopper",
               next_of_kin_phone: "+353810000099",
               confirmation_token: "ctok_complimentary",
               coupon_code: "COMPLIMENTARY"
             })

    assert_received {:prepare_payment, "COMPLIMENTARY"}
    assert_received {:create_customer, _attrs}
    assert_received {:provision_membership, %{complimentary: true}}
    assert Repo.get!(Invitation, invitation.id).status == "accepted"
    assert Repo.exists?(ExternalIdentity)
    refute Repo.exists?(PrincipalToken)
  end

  test "duplicate Continue returns the current projection and only explicit Retry resumes Stripe" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _state} =
      Onboarding.verify_discord(started.continuation_id, %{
        "sub" => "retry-discord-subject",
        "preferred_username" => "retry-member"
      })

    timeout = {:http_error, :timeout}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, timeout})

    attrs = %{
      next_of_kin_name: "Grace Hopper",
      next_of_kin_phone: "+353810000099",
      confirmation_token: "ctok_original",
      coupon_code: nil
    }

    assert {:ok, %{state: "paymentReady"}} =
             Onboarding.continue_acceptance(started.continuation_id)

    assert {:error, {:provider_unavailable, ^timeout}} =
             Onboarding.submit_payment(started.continuation_id, attrs)

    assert_received {:prepare_payment, nil}
    assert_received {:create_customer, _attrs}
    assert_received {:provision_membership, %{confirmation_token: "ctok_original"}}

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert %InvitationAcceptanceAttempt{status: "payment_pending"} = attempt

    assert_enqueued(worker: AcceptanceRecoveryWorker, args: %{"attempt_id" => attempt.id})

    jobs = all_enqueued(worker: AcceptanceRecoveryWorker)
    assert [%{args: %{"attempt_id" => recovery_attempt_id}}] = jobs

    assert recovery_attempt_id ==
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id).id

    refute inspect(jobs) =~ "ctok_original"
    refute inspect(jobs) =~ "retry-discord-subject"

    assert :ok =
             StripeWebhooks.process_event(%{
               "type" => "account.updated",
               "data" => %{
                 "object" => %{
                   "id" => "acct_acceptance_recovery",
                   "customer" => "cus_onboarding"
                 }
               }
             })

    assert :ok =
             StripeWebhooks.process_event(%{
               "type" => "account.updated",
               "data" => %{
                 "object" => %{
                   "id" => "acct_acceptance_recovery_replay",
                   "customer" => %{"id" => "cus_onboarding"}
                 }
               }
             })

    assert [_one_recovery_job] = all_enqueued(worker: AcceptanceRecoveryWorker)

    assert {:ok,
            %{
              state: "paymentPending",
              discord_verified: true,
              retry_allowed: true
            }} = Onboarding.acceptance_state(started.continuation_id)

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{state: "paymentPending"}} =
             Onboarding.submit_payment(started.continuation_id, %{
               attrs
               | next_of_kin_name: "Must not replace durable input",
                 confirmation_token: "ctok_must_not_be_used"
             })

    refute_received {:prepare_payment, _}
    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}

    assert {:ok, %{state: "accepted"}} = Onboarding.retry_acceptance(started.continuation_id)
    assert_received {:provision_membership, %{confirmation_token: "ctok_original"}}
    refute_received {:provision_membership, %{confirmation_token: "ctok_must_not_be_used"}}
  end

  test "a processing SEPA PaymentIntent finalizes acceptance while settlement remains pending" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _state} =
      Onboarding.verify_discord(started.continuation_id, %{
        "sub" => "processing-sepa-discord-subject",
        "preferred_username" => "processing-sepa-member"
      })

    assert {:ok, %{state: "paymentReady"}} =
             Onboarding.continue_acceptance(started.continuation_id)

    stripe_state = %{
      "payment_state" => "pending",
      "payment_intent_status" => "processing"
    }

    Application.put_env(:dhc, :onboarding_stripe_result, {:pending, stripe_state})

    assert {:ok, %{state: "accepted"}} =
             Onboarding.submit_payment(started.continuation_id, %{
               next_of_kin_name: "Grace Hopper",
               next_of_kin_phone: "+353810000099",
               confirmation_token: "ctok_processing_sepa"
             })

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert attempt.status == "completed"
    assert Map.take(attempt.stripe_state, Map.keys(stripe_state)) == stripe_state
    assert Repo.get!(Invitation, invitation.id).status == "accepted"
    assert Repo.get(Principal, invitation.prospective_principal_id)

    assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
    assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
  end

  test "incomplete PaymentIntent outcomes remain durable without converting the invitation" do
    outcomes = [
      {%{"payment_state" => "needs_action", "payment_intent_status" => "requires_action"},
       "paymentNeedsAction"},
      {%{"payment_state" => "terminal", "payment_intent_status" => "canceled"}, "paymentTerminal"}
    ]

    for {stripe_state, expected_state} <- outcomes do
      invitation = insert_invitation!()

      {:ok, started} =
        Onboarding.start_acceptance(
          invitation.id,
          invitation.email,
          Date.to_iso8601(invitation.date_of_birth)
        )

      {:ok, _state} =
        Onboarding.verify_discord(started.continuation_id, %{
          "sub" => "#{expected_state}-discord-subject",
          "preferred_username" => expected_state
        })

      assert {:ok, %{state: "paymentReady"}} =
               Onboarding.continue_acceptance(started.continuation_id)

      Application.put_env(:dhc, :onboarding_stripe_result, {:pending, stripe_state})

      assert {:ok, %{state: ^expected_state}} =
               Onboarding.submit_payment(started.continuation_id, %{
                 next_of_kin_name: "Grace Hopper",
                 next_of_kin_phone: "+353810000099",
                 confirmation_token: "ctok_#{expected_state}"
               })

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "payment_pending"
      assert Map.take(attempt.stripe_state, Map.keys(stripe_state)) == stripe_state
      assert Repo.get!(Invitation, invitation.id).status == "pending"
      refute Repo.get(Principal, invitation.prospective_principal_id)
    end
  end

  test "Discord-bound finalization rollback leaves no partial conversion records" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _state} =
      Onboarding.verify_discord(started.continuation_id, %{
        "sub" => "rollback-discord-subject",
        "preferred_username" => "rollback-member"
      })

    conflicting_principal =
      %Principal{id: Ecto.UUID.generate(), email: invitation.email}
      |> Repo.insert!()

    assert {:ok, %{state: "paymentReady"}} =
             Onboarding.continue_acceptance(started.continuation_id)

    assert {:error, :principal_creation_failed} =
             Onboarding.submit_payment(started.continuation_id, %{
               next_of_kin_name: "Grace Hopper",
               next_of_kin_phone: "+353810000099",
               confirmation_token: "ctok_rollback",
               coupon_code: nil
             })

    refute Repo.get(Principal, invitation.prospective_principal_id)
    refute Repo.get(MemberProfile, invitation.prospective_principal_id)
    refute Repo.get_by(UserProfile, principal_id: invitation.prospective_principal_id)
    refute Repo.get_by(ExternalIdentity, provider_subject: "rollback-discord-subject")
    refute Repo.get_by(UserRole, principal_id: invitation.prospective_principal_id)
    assert Repo.get!(Invitation, invitation.id).status == "pending"

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert attempt.status == "provisioned"
    assert Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)

    assert %InvitationAcceptanceDiscordContinuation{
             status: "verified",
             provider_subject: "rollback-discord-subject"
           } = Repo.get!(InvitationAcceptanceDiscordContinuation, started.continuation_id)

    Repo.delete!(conflicting_principal)

    invitation
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})

    assert %ExternalIdentity{
             provider: "discord",
             provider_subject: "rollback-discord-subject"
           } = Repo.get_by!(ExternalIdentity, principal_id: invitation.prospective_principal_id)

    assert %InvitationAcceptanceDiscordContinuation{
             status: "consumed",
             provider_subject: nil,
             display_metadata: %{}
           } = Repo.get!(InvitationAcceptanceDiscordContinuation, started.continuation_id)

    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
  end

  test "terminal Discord-bound payment failure releases proof and permits a fresh attempt" do
    invitation = insert_invitation!()

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _state} =
      Onboarding.verify_discord(started.continuation_id, %{
        "sub" => "declined-discord-subject",
        "preferred_username" => "declined-member"
      })

    decline = {:setup_intent_failed, "requires_payment_method"}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, decline})

    assert {:ok, %{state: "paymentReady"}} =
             Onboarding.continue_acceptance(started.continuation_id)

    assert {:error, {:payment_failed, ^decline}} =
             Onboarding.submit_payment(started.continuation_id, %{
               next_of_kin_name: "Grace Hopper",
               next_of_kin_phone: "+353810000099",
               confirmation_token: "ctok_declined_discord",
               coupon_code: nil
             })

    assert %InvitationAcceptanceAttempt{status: "declined"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    assert %InvitationAcceptanceDiscordContinuation{
             status: "failed",
             provider_subject: nil,
             display_metadata: %{}
           } = Repo.get!(InvitationAcceptanceDiscordContinuation, started.continuation_id)

    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, fresh} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    refute fresh.continuation_id == started.continuation_id
    assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 2
  end

  test "legacy verification and acceptance stay fenced after a protected flow starts" do
    invitation = insert_invitation!()
    {:ok, legacy_token} = token_for(invitation)

    assert {:ok, _state} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    attempt
    |> Ecto.Changeset.change(
      status: "declined",
      concluded_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert {:error, :invalid_credentials} =
             Onboarding.verify_credentials(
               invitation.id,
               invitation.email,
               invitation.date_of_birth
             )

    assert {:error, :discord_verification_required} =
             Onboarding.accept(
               invitation.id,
               legacy_token,
               "Next of Kin",
               "+353810000001",
               %{confirmation_token: "ctok_must_not_be_used"}
             )

    attempt = Repo.get!(InvitationAcceptanceAttempt, attempt.id)
    assert attempt.acceptance_data == %{}
    assert attempt.stripe_customer_id == nil
    assert attempt.stripe_state == %{}
    assert Repo.get!(Invitation, invitation.id).status == "pending"
    refute Repo.get(Principal, invitation.prospective_principal_id)
    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}
  end

  test "a Continuation cannot reference an Attempt from another Invitation" do
    invitation = insert_invitation!()
    other_invitation = insert_invitation!()

    attempt =
      %InvitationAcceptanceAttempt{invitation_id: invitation.id, acceptance_data: %{}}
      |> Repo.insert!()

    assert_raise Ecto.ConstraintError, fn ->
      %InvitationAcceptanceDiscordContinuation{
        invitation_id: other_invitation.id,
        attempt_id: attempt.id,
        expires_at:
          DateTime.utc_now()
          |> DateTime.add(15, :minute)
          |> DateTime.truncate(:second)
      }
      |> Repo.insert!()
    end
  end

  test "missing or mismatched opaque proof returns restart verification" do
    invitation = insert_invitation!()

    assert {:ok, state} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    assert {:error, :restart_verification} =
             Onboarding.acceptance_state(Ecto.UUID.generate())

    assert {:ok, %{state: "awaiting_oauth"}} =
             Onboarding.acceptance_state(state.continuation_id)
  end

  test "an active pre-OAuth attempt cannot restart after the Invitation expires" do
    invitation = insert_invitation!()

    assert {:ok, _state} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    invitation
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert {:error, :invalid_invitation} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    assert Repo.aggregate(InvitationAcceptanceDiscordContinuation, :count) == 1
  end

  test "a replay-ineligible active attempt cannot start a Discord continuation" do
    invitation = insert_invitation!()

    %InvitationAcceptanceAttempt{
      invitation_id: invitation.id,
      status: "processing",
      acceptance_data: %{"payment" => %{"confirmation_token" => "existing"}}
    }
    |> Repo.insert!()

    assert {:error, :invalid_invitation} =
             Onboarding.start_acceptance(
               invitation.id,
               invitation.email,
               Date.to_iso8601(invitation.date_of_birth)
             )

    refute Repo.exists?(InvitationAcceptanceDiscordContinuation)
  end

  test "the maintenance worker expires and zeroizes abandoned verified continuations" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)
    continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, continuation_id)
    future_now = DateTime.add(continuation.expires_at, 1, :second)
    Application.put_env(:dhc, :onboarding_discord_expiry_clock, fn -> future_now end)

    assert :ok = perform_job(DiscordContinuationExpiryWorker, %{})

    continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, continuation_id)
    assert continuation.status == "expired"
    assert continuation.provider_subject == nil
    assert continuation.display_metadata == %{}
    assert is_binary(continuation.subject_fingerprint)
    refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)

    assert {:ok, 0} = Onboarding.expire_discord_continuations()
  end

  test "an annual decline cancels partial Membership provisioning before a retry" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)
    decline = {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, decline})

    Application.put_env(:dhc, :onboarding_stripe_progress, %{
      "monthly_subscription_id" => "sub_monthly_onboarding",
      "monthly_confirmed" => true,
      "annual_subscription_id" => "sub_annual_onboarding"
    })

    attrs = %{confirmation_token: "ctok_declined"}

    assert {:error, {:payment_failed, ^decline}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               attrs
             )

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
    continuation_id = continuation_for(invitation)

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               attrs
             )

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
    continuation_id = continuation_for(invitation)
    failure = {:setup_intent_failed, "requires_payment_method"}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, failure})

    assert {:error, {:payment_failed, ^failure}} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_invalid"
             })

    assert %InvitationAcceptanceAttempt{status: "declined"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    assert %InvitationAcceptanceDiscordContinuation{
             status: "failed",
             provider_subject: nil,
             subject_fingerprint: nil,
             display_metadata: %{}
           } = Repo.get!(InvitationAcceptanceDiscordContinuation, continuation_id)

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
    continuation_id = continuation_for(invitation)

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
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
    continuation_id = continuation_for(invitation)
    decline = {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, decline})
    Application.put_env(:dhc, :onboarding_stripe_cancel_result, {:error, :stripe_unavailable})

    assert {:error, {:payment_failed, ^decline}} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_declined"
             })

    attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    assert attempt.status == "cleanup_pending"
    assert_enqueued(worker: AcceptanceRecoveryWorker, args: %{"attempt_id" => attempt.id})

    assert {:error, :payment_cleanup_pending} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_corrected"
             })

    refute_received {:provision_membership, %{confirmation_token: "ctok_corrected"}}

    assert {:error, :stripe_unavailable} =
             perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})

    Application.put_env(:dhc, :onboarding_stripe_cancel_result, :ok)

    assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
    assert Repo.get!(InvitationAcceptanceAttempt, attempt.id).status == "declined"
  end

  test "an active attempt keeps its original Stripe parameters across transport retries" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})

    original_attrs = %{
      confirmation_token: "ctok_original",
      coupon_code: "WELCOME",
      mandate_context: %{ip_address: "127.0.0.1", user_agent: "first-agent"}
    }

    assert {:error, {:payment_failed, {:http_error, :timeout}}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               original_attrs
             )

    assert_received {:prepare_payment, "WELCOME"}
    assert_received {:provision_membership, %{confirmation_token: "ctok_original"}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Updated Kin",
               "+353810000002",
               %{
                 confirmation_token: "ctok_changed",
                 coupon_code: "CHANGED",
                 mandate_context: %{ip_address: "127.0.0.2", user_agent: "second-agent"}
               }
             )

    refute_received {:prepare_payment, "CHANGED"}

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
    assert attempt.acceptance_data["next_of_kin_name"] == "Next of Kin"
    refute Map.has_key?(attempt.acceptance_data, "payment")
    assert attempt.stripe_state["payment_plan"]["promotion_code_id"] == "promo_onboarding"
  end

  test "a live-shaped Stripe customer rejection closes the attempt" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)
    decline = {:stripe_customer, {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}}
    Application.put_env(:dhc, :onboarding_stripe_customer_result, {:error, decline})

    assert {:error, {:payment_failed, ^decline}} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_declined"
             })

    assert %InvitationAcceptanceAttempt{status: "declined", concluded_at: %DateTime{}} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
  end

  test "a Stripe rate limit keeps the active attempt available for retry" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)
    rate_limit = {:stripe_api, 429, %{"error" => %{"code" => "rate_limit"}}}
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, rate_limit})

    attrs = %{confirmation_token: "ctok_retry"}

    assert {:error, {:payment_failed, ^rate_limit}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               attrs
             )

    assert %InvitationAcceptanceAttempt{status: "payment_pending", concluded_at: nil} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               attrs
             )

    assert 1 ==
             Repo.aggregate(
               from(a in InvitationAcceptanceAttempt, where: a.invitation_id == ^invitation.id),
               :count
             )
  end

  test "a consumed Discord proof can resume its active attempt after both expiries" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)
    Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})

    attrs = %{confirmation_token: "ctok_before_expiry"}

    assert {:error, {:payment_failed, {:http_error, :timeout}}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               attrs
             )

    invitation
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    InvitationAcceptanceDiscordContinuation
    |> Repo.get!(continuation_id)
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

    assert {:ok, %{member_id: _}} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               attrs
             )

    assert %InvitationAcceptanceAttempt{status: "completed"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
  end

  test "a provisioned attempt is recoverable after local conversion rolls back" do
    invitation = insert_invitation!()
    continuation_id = continuation_for(invitation)

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
               continuation_id,
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
    continuation_id = continuation_for(invitation)

    %Principal{id: Ecto.UUID.generate(), email: invitation.email}
    |> Repo.insert!()

    assert {:error, :invalid_invitation} =
             Onboarding.accept(
               invitation.id,
               continuation_id,
               "Next of Kin",
               "+353810000001",
               %{confirmation_token: "ctok_must_not_be_used"}
             )

    refute_received {:create_customer, _}
    refute_received {:provision_membership, _}

    assert %InvitationAcceptanceAttempt{acceptance_data: %{}, status: "processing"} =
             Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

    assert Repo.get!(Invitation, invitation.id).status == "pending"
  end

  test "secure acceptance reuses the waitlist UserProfile and preserves intake data" do
    invitation =
      insert_waitlist_invitation!(
        first_name: "IntakeFirst",
        last_name: "IntakeLast",
        gender: "non-binary",
        pronouns: "they/them",
        phone_number: "+353871234567",
        social_media_consent: "yes_recognizable",
        medical_conditions: "asthma"
      )

    continuation_id = continuation_for(invitation)

    assert {:ok, %{member_id: member_id}} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_waitlist_reuse"
             })

    profiles = Repo.all(from(up in UserProfile, where: up.waitlist_id == ^invitation.waitlist_id))
    assert [reused] = profiles
    assert reused.principal_id == member_id
    assert reused.is_active
    assert reused.customer_id == "cus_onboarding"
    assert reused.first_name == "IntakeFirst"
    assert reused.last_name == "IntakeLast"
    assert reused.date_of_birth == ~D[1990-01-01]
    assert reused.gender == "non-binary"
    assert reused.pronouns == "they/them"
    assert reused.phone_number == "+353871234567"
    assert reused.social_media_consent == "yes_recognizable"
    assert reused.medical_conditions == "asthma"
    assert Repo.get!(MemberProfile, member_id).user_profile_id == reused.id
  end

  test "secure acceptance preserves the guardian linked to the waitlist UserProfile" do
    invitation = insert_waitlist_invitation!(guardian: true)
    profile = Repo.get_by!(UserProfile, waitlist_id: invitation.waitlist_id)
    continuation_id = continuation_for(invitation)

    assert {:ok, %{member_id: _member_id}} =
             Onboarding.accept(invitation.id, continuation_id, "Next of Kin", "+353810000001", %{
               confirmation_token: "ctok_waitlist_guardian"
             })

    assert [["Parent", "Guardian"]] =
             Repo.query!(
               "SELECT first_name, last_name FROM waitlist_guardians WHERE profile_id = $1",
               [Ecto.UUID.dump!(profile.id)]
             ).rows

    assert Repo.aggregate(
             from(up in UserProfile, where: up.waitlist_id == ^invitation.waitlist_id),
             :count
           ) == 1
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

  defp insert_waitlist_invitation!(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    waitlist_id = Ecto.UUID.generate()

    Repo.insert!(%Dhc.Waitlist.WaitlistEntry{
      id: waitlist_id,
      email: "waitlist-onboarding-#{System.unique_integer([:positive])}@example.com",
      status: "invited",
      initial_registration_date: now,
      last_status_change: now
    })

    waitlist = Repo.get!(Dhc.Waitlist.WaitlistEntry, waitlist_id)
    profile_id = Ecto.UUID.generate()

    Repo.insert!(%UserProfile{
      id: profile_id,
      waitlist_id: waitlist_id,
      first_name: Keyword.get(attrs, :first_name, "IntakeFirst"),
      last_name: Keyword.get(attrs, :last_name, "IntakeLast"),
      is_active: false,
      date_of_birth: ~D[1990-01-01],
      gender: Keyword.get(attrs, :gender, "man (cis)"),
      pronouns: Keyword.get(attrs, :pronouns),
      phone_number: Keyword.get(attrs, :phone_number, "+353810000000"),
      social_media_consent: Keyword.get(attrs, :social_media_consent, "no"),
      medical_conditions: Keyword.get(attrs, :medical_conditions)
    })

    if Keyword.get(attrs, :guardian, false) do
      Repo.insert_all("waitlist_guardians", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          profile_id: Ecto.UUID.dump!(profile_id),
          first_name: "Parent",
          last_name: "Guardian",
          phone_number: "+353 1 111 1111",
          created_at: now
        }
      ])
    end

    %Invitation{
      email: waitlist.email,
      prospective_principal_id: Ecto.UUID.generate(),
      waitlist_id: waitlist_id,
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

  defp continuation_for(invitation) do
    {:ok, state} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, %{state: "discordVerified"}} =
      Onboarding.verify_discord(state.continuation_id, %{
        "sub" => "onboarding-subject-#{System.unique_integer([:positive])}",
        "preferred_username" => "onboarding-member"
      })

    state.continuation_id
  end
end
