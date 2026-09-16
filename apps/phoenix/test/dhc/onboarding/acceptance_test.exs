defmodule Dhc.Onboarding.AcceptanceTest do
  @moduledoc """
  Boundary tests for the acceptance session: every scenario drives
  `Dhc.Onboarding.Acceptance` through its public handle against PostgreSQL and
  the Stripe test adapter, and asserts on durable rows plus the safe view.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query

  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Auth.Principal
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Auth.UserRole
  alias Dhc.Discord.JoinGrant
  alias Dhc.Discord.Workers.GuildJoinWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding
  alias Dhc.Onboarding.Acceptance
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordCollisionAuditEvent
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Onboarding.Workers.AcceptanceRecoveryWorker
  alias Dhc.Onboarding.Workers.DiscordContinuationExpiryWorker
  alias Dhc.StripeWebhooks
  alias Dhc.UserProfiles.UserProfile

  @env_keys [
    :onboarding_stripe_adapter,
    :onboarding_stripe_result,
    :onboarding_stripe_prepare_result,
    :onboarding_stripe_customer_result,
    :onboarding_stripe_cancel_result,
    :onboarding_stripe_progress,
    :onboarding_acceptance_clock,
    :onboarding_test_pid,
    :acceptance_recovery_delay_seconds,
    :membership_tier_coupons
  ]

  @secret_keys ~w(operation_token confirmation_token provider_subject idempotency_key stripe_state attempt_id continuation_id payment)a

  @payment %{
    next_of_kin_name: "Grace Hopper",
    next_of_kin_phone: "+353810000099",
    confirmation_token: "ctok_success",
    coupon_code: nil,
    mandate_context: %{ip_address: "127.0.0.1", user_agent: "test-agent"}
  }

  setup do
    originals = Map.new(@env_keys, &{&1, Application.get_env(:dhc, &1)})

    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.Onboarding.StripeAdapter.Test)
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
    Application.put_env(:dhc, :onboarding_test_pid, self())

    on_exit(fn -> Enum.each(originals, fn {key, value} -> restore_env(key, value) end) end)
    :ok
  end

  # ── Opening and resuming ─────────────────────────────────────────────

  describe "open/4" do
    test "verifies credentials and opens one protected session per Invitation" do
      invitation = insert_invitation!()

      assert {:ok, handle, %{state: "awaiting_oauth", expires_at: %DateTime{}} = view} =
               open(invitation)

      assert_safe(view)
      assert {:ok, %{state: "awaiting_oauth"}} = Acceptance.view(handle)

      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
      assert Repo.aggregate(InvitationAcceptanceDiscordContinuation, :count) == 1
      refute Repo.get(Principal, invitation.prospective_principal_id)
      refute_received {:create_customer, _}
    end

    test "refuses a second browser without proof and resumes the browser that holds it" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = open(invitation)

      assert {:error, :missing_browser_proof} = open(invitation)
      assert {:ok, ^handle, %{state: "awaiting_oauth"}} = open(invitation, handle)
      assert {:error, :missing_browser_proof} = open(invitation, Ecto.UUID.generate())
      assert {:error, :missing_browser_proof} = open(invitation, "not-a-handle")

      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
      assert Repo.aggregate(InvitationAcceptanceDiscordContinuation, :count) == 1
    end

    test "rejects wrong credentials, malformed ids, and ineligible Invitations" do
      invitation = insert_invitation!()

      assert {:error, :invalid_credentials} =
               Acceptance.open(invitation.id, "wrong@example.com", "1990-01-01")

      assert {:error, :invalid_credentials} =
               Acceptance.open("not-an-id", invitation.email, "1990-01-01")

      for ineligible <- [
            insert_invitation!(status: "revoked"),
            insert_invitation!(status: "accepted"),
            insert_invitation!(expires_at: seconds_ago(1))
          ] do
        assert {:error, :invalid_credentials} = open(ineligible)
      end

      refute Repo.exists?(InvitationAcceptanceAttempt)
    end

    test "an Invitation whose Principal already exists cannot open a session" do
      invitation = insert_invitation!()
      Repo.insert!(%Principal{id: Ecto.UUID.generate(), email: invitation.email})

      assert {:error, :invalid_invitation} = open(invitation)
      refute Repo.exists?(InvitationAcceptanceAttempt)
    end

    test "an active pre-OAuth Attempt cannot restart after the Invitation expires" do
      invitation = insert_invitation!()
      {:ok, _handle, _view} = open(invitation)
      expire_invitation!(invitation)

      assert {:error, :invalid_invitation} = open(invitation)
      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    end

    test "an Attempt that already bound payment input cannot start a fresh session" do
      invitation = insert_invitation!()

      Repo.insert!(%InvitationAcceptanceAttempt{
        invitation_id: invitation.id,
        status: "processing",
        acceptance_data: %{"payment" => %{"confirmation_token" => "existing"}}
      })

      assert {:error, :invalid_invitation} = open(invitation)
      refute Repo.exists?(InvitationAcceptanceDiscordContinuation)
    end

    test "an expired unverified session is replaced by a fresh one on the same Attempt" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = open(invitation)
      expire_continuation!(handle)

      assert {:ok, fresh_handle, %{state: "awaiting_oauth"}} = open(invitation)
      refute fresh_handle == handle

      assert Repo.get!(InvitationAcceptanceDiscordContinuation, handle).status == "expired"
      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    end
  end

  # ── Reading ──────────────────────────────────────────────────────────

  describe "view/1" do
    test "unknown, malformed, and missing handles read as restart" do
      assert {:error, :restart_verification} = Acceptance.view(Ecto.UUID.generate())
      assert {:error, :restart_verification} = Acceptance.view("garbage")
      assert {:error, :restart_verification} = Acceptance.view(nil)
    end

    test "expiry on read and the expiry sweep reach the same terminal outcome" do
      first = insert_invitation!()
      second = insert_invitation!()
      {:ok, read_handle, _} = verified(first, "expire-on-read")
      {:ok, swept_handle, _} = verified(second, "expire-by-sweep")
      expire_continuation!(read_handle)
      expire_continuation!(swept_handle)

      assert {:error, :restart_verification} = Acceptance.view(read_handle)
      assert :ok = perform_job(DiscordContinuationExpiryWorker, %{})

      for handle <- [read_handle, swept_handle] do
        assert %InvitationAcceptanceDiscordContinuation{
                 status: "expired",
                 provider_subject: nil,
                 display_metadata: %{},
                 subject_fingerprint: fingerprint
               } = Repo.get!(InvitationAcceptanceDiscordContinuation, handle)

        assert is_binary(fingerprint)
        attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation_of(handle))
        assert attempt.status == "declined"
        assert attempt.last_error == "discord_expired"
      end

      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      assert {:ok, _fresh, %{state: "awaiting_oauth"}} = open(first)
    end

    test "malformed relationships between rows produce controlled errors, not crashes" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "malformed-subject")
      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

      # A second Continuation on the same Attempt that never consumed its proof.
      stray =
        Repo.insert!(%InvitationAcceptanceDiscordContinuation{
          invitation_id: invitation.id,
          attempt_id: attempt.id,
          status: "cancelled",
          concluded_at: seconds_ago(1),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:second)
        })

      assert {:error, :restart_verification} = Acceptance.view(stray.id)
      assert {:error, :invalid_continuation} = Acceptance.consume_proof(stray.id)
      assert {:error, :invalid_continuation} = Acceptance.cancel_discord(stray.id)
      assert {:error, :invalid_continuation} = Acceptance.retry(stray.id)
      assert {:ok, %{state: "paymentReady"}} = Acceptance.view(handle)

      # The Attempt records a Continuation that belongs to another Attempt.
      other = insert_invitation!()
      {:ok, other_handle, _view} = open(other)

      attempt
      |> Ecto.Changeset.change(
        status: "payment_pending",
        acceptance_data: Map.put(attempt.acceptance_data, "continuation_id", other_handle)
      )
      |> Repo.update!()

      assert {:error, :payment_fence_invalid} = Acceptance.recover(attempt.id)
      assert {:error, :invalid_continuation} = Acceptance.retry(handle)
      assert Repo.get!(InvitationAcceptanceAttempt, attempt.id).status == "payment_pending"
    end
  end

  # ── Discord ──────────────────────────────────────────────────────────

  describe "verify_discord/3" do
    test "binds the subject, stores the join grant, and is idempotent for the same subject" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = open(invitation)
      email = invitation.email

      assert {:ok, %{state: "discordVerified", invitation_email: ^email, discord: discord} = view} =
               Acceptance.verify_discord(
                 handle,
                 %{
                   "sub" => "paid-discord-subject",
                   "preferred_username" => "paid-member",
                   "picture" => "https://cdn.example.com/paid-member.png"
                 },
                 %{"access_token" => "discord-join-token", "expires_in" => 604_800}
               )

      assert discord == %{
               "username" => "paid-member",
               "avatarUrl" => "https://cdn.example.com/paid-member.png"
             }

      assert_safe(view)

      assert {:ok, %{state: "discordVerified"}} =
               Acceptance.verify_discord(handle, %{"sub" => "paid-discord-subject"})

      assert %InvitationAcceptanceDiscordSubjectClaim{provider_subject: "paid-discord-subject"} =
               Repo.one!(InvitationAcceptanceDiscordSubjectClaim)

      assert %JoinGrant{continuation_id: ^handle} = Repo.one!(JoinGrant)
      refute Repo.exists?(ExternalIdentity)
    end

    test "rejects missing subjects, unknown handles, and a different subject on a verified session" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "first-subject")

      assert {:error, :invalid_continuation} = Acceptance.verify_discord(handle, %{})
      assert {:error, :invalid_continuation} = Acceptance.verify_discord(handle, %{"sub" => ""})

      assert {:error, :invalid_continuation} =
               Acceptance.verify_discord(Ecto.UUID.generate(), %{"sub" => "x"})

      assert {:error, :invalid_continuation} =
               Acceptance.verify_discord(handle, %{"sub" => "another-subject"})
    end

    test "a subject owned by a live External Identity collides without exposing the owner" do
      invitation = insert_invitation!()
      principal = Repo.insert!(%Principal{email: "existing-discord-owner@example.com"})

      Repo.insert!(%ExternalIdentity{
        principal_id: principal.id,
        provider: "discord",
        provider_subject: "owned-subject",
        metadata: %{}
      })

      {:ok, handle, _view} = open(invitation)

      assert {:error, :collision} =
               Acceptance.verify_discord(handle, %{
                 "sub" => "owned-subject",
                 "preferred_username" => "must-not-identify-owner"
               })

      assert {:ok, %{state: "discordCollision"} = view} = Acceptance.view(handle)
      assert_safe(view)

      continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, handle)
      assert continuation.status == "collision"
      assert continuation.provider_subject == nil
      assert continuation.display_metadata == %{}
      assert Repo.get!(InvitationAcceptanceAttempt, continuation.attempt_id).status == "declined"
      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)

      assert %InvitationAcceptanceDiscordCollisionAuditEvent{
               reason_code: "external_identity",
               existing_principal_id: existing_principal_id,
               subject_fingerprint: fingerprint
             } = Repo.one!(InvitationAcceptanceDiscordCollisionAuditEvent)

      assert existing_principal_id == principal.id
      assert fingerprint == continuation.subject_fingerprint
    end

    test "a retired External Identity does not block a fresh claim" do
      invitation = insert_invitation!()
      principal = Repo.insert!(%Principal{email: "retired-discord-owner@example.com"})

      Repo.insert!(%ExternalIdentity{
        principal_id: principal.id,
        provider: "discord",
        provider_subject: "retired-subject",
        metadata: %{},
        sign_in_disabled_at: DateTime.utc_now(),
        retired_at: DateTime.utc_now()
      })

      {:ok, handle, _view} = open(invitation)

      assert {:ok, %{state: "discordVerified"}} =
               Acceptance.verify_discord(handle, %{"sub" => "retired-subject"})
    end

    test "two sessions claiming one subject yield one winner and one audited collision" do
      first = insert_invitation!()
      second = insert_invitation!()
      {:ok, first_handle, _} = open(first)
      {:ok, second_handle, _} = open(second)
      claims = %{"sub" => "one-subject", "preferred_username" => "same-account"}

      assert {:ok, %{state: "discordVerified"}} = Acceptance.verify_discord(first_handle, claims)
      assert {:error, :collision} = Acceptance.verify_discord(second_handle, claims)

      assert Repo.aggregate(InvitationAcceptanceDiscordSubjectClaim, :count) == 1

      assert %InvitationAcceptanceDiscordCollisionAuditEvent{
               continuation_id: ^second_handle,
               existing_principal_id: nil,
               reason_code: "active_claim"
             } = Repo.one!(InvitationAcceptanceDiscordCollisionAuditEvent)
    end
  end

  describe "cancel_discord/1 and fail_discord/2" do
    test "cancelling a verified session zeroizes it and releases its claim" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "cancel-subject")

      assert {:ok, %{state: "restartVerification"}} = Acceptance.cancel_discord(handle)
      assert {:error, :invalid_continuation} = Acceptance.cancel_discord(handle)

      continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, handle)
      assert continuation.status == "cancelled"
      assert continuation.provider_subject == nil
      assert is_binary(continuation.subject_fingerprint)
      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      assert Repo.get!(InvitationAcceptanceAttempt, continuation.attempt_id).status == "declined"
      assert {:ok, _fresh, %{state: "awaiting_oauth"}} = open(invitation)
    end

    test "a provider failure before any subject reads as unavailable; cancellation as restart" do
      failed = insert_invitation!()
      cancelled = insert_invitation!()
      {:ok, failed_handle, _} = open(failed)
      {:ok, cancelled_handle, _} = open(cancelled)

      assert {:ok, %{state: "discordUnavailable"}} =
               Acceptance.fail_discord(failed_handle, :failed)

      assert {:ok, %{state: "discordUnavailable"}} = Acceptance.view(failed_handle)
      assert {:error, :invalid_continuation} = Acceptance.fail_discord(failed_handle, :failed)

      assert {:ok, %{state: "restartVerification"}} =
               Acceptance.fail_discord(cancelled_handle, :cancelled)

      assert Repo.get!(InvitationAcceptanceDiscordContinuation, failed_handle).status == "failed"

      assert Repo.get!(InvitationAcceptanceDiscordContinuation, cancelled_handle).status ==
               "cancelled"

      refute Repo.exists?(ExternalIdentity)
    end

    test "a verified session cannot be failed as a provider error" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "already-verified")

      assert {:error, :invalid_continuation} = Acceptance.fail_discord(handle, :failed)
      assert Repo.get!(InvitationAcceptanceDiscordContinuation, handle).status == "verified"
    end
  end

  describe "resume_path/1" do
    test "returns the dashboard resume route only for a known handle" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = open(invitation)

      assert {:ok, "/members/signup/" <> rest} = Acceptance.resume_path(handle)
      assert rest == "#{invitation.id}/resume"
      assert {:error, :invalid_continuation} = Acceptance.resume_path(Ecto.UUID.generate())
      assert {:error, :invalid_continuation} = Acceptance.resume_path("junk")
      assert {:error, :invalid_continuation} = Acceptance.resume_path(nil)
    end

    test "still resolves after the OAuth callback ended the session" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = open(invitation)
      {:ok, %{state: "discordUnavailable"}} = Acceptance.fail_discord(handle, :failed)

      assert {:ok, "/members/signup/#{invitation.id}/resume"} == Acceptance.resume_path(handle)
    end

    test "a Continuation that ended underneath the callback still lands on its own Invitation" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "superseded-resume")

      expire_continuation!(handle)
      assert {:error, :restart_verification} = Acceptance.view(handle)

      assert {:ok, "/members/signup/#{invitation.id}/resume"} == Acceptance.resume_path(handle)
    end

    test "a stray Continuation whose Attempt was consumed by another proof resolves through the graph" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "stray-resume")
      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

      # The composite FK (attempt_id, invitation_id) forbids re-pointing a
      # Continuation at another Invitation, so the malformed shape the database
      # admits is a second Continuation on an Attempt bound to a different
      # proof. It resolves to its own Invitation and nowhere else, and the
      # dashboard page it lands on then reads restart.
      stray =
        Repo.insert!(%InvitationAcceptanceDiscordContinuation{
          invitation_id: invitation.id,
          attempt_id: attempt.id,
          status: "cancelled",
          concluded_at: seconds_ago(1),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:second)
        })

      assert {:ok, "/members/signup/#{invitation.id}/resume"} == Acceptance.resume_path(stray.id)
      assert {:error, :restart_verification} = Acceptance.view(stray.id)
      assert {:ok, %{state: "paymentReady"}} = Acceptance.view(handle)
    end
  end

  # ── Proof consumption ────────────────────────────────────────────────

  describe "consume_proof/1" do
    test "consumes the verified proof exactly once and then returns the current projection" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "consume-once")

      assert {:ok, %{state: "paymentReady", complimentary: false} = view} =
               Acceptance.consume_proof(handle)

      assert_safe(view)
      assert {:ok, %{state: "paymentReady"}} = Acceptance.consume_proof(handle)
      assert {:ok, %{state: "paymentReady"}} = Acceptance.view(handle)
      assert {:error, :invalid_continuation} = Acceptance.cancel_discord(handle)

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.acceptance_data == %{"continuation_id" => handle}
      assert Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      refute_received {:prepare_payment, _}
    end

    test "an unverified, expired, or claim-less session cannot be consumed" do
      unverified = insert_invitation!()
      {:ok, unverified_handle, _} = open(unverified)
      assert {:error, :invalid_continuation} = Acceptance.consume_proof(unverified_handle)

      expired = insert_invitation!()
      {:ok, expired_handle, _} = verified(expired, "expired-proof")
      expire_continuation!(expired_handle)
      assert {:error, :invalid_continuation} = Acceptance.consume_proof(expired_handle)

      claimless = insert_invitation!()
      {:ok, claimless_handle, _} = verified(claimless, "claimless-proof")
      Repo.query!("SET CONSTRAINTS ALL DEFERRED")
      Repo.delete_all(InvitationAcceptanceDiscordSubjectClaim)
      assert {:error, :invalid_continuation} = Acceptance.consume_proof(claimless_handle)
    end
  end

  # ── Pricing ──────────────────────────────────────────────────────────

  describe "preview_pricing/2" do
    setup do
      Application.put_env(:dhc, :membership_tier_coupons,
        coach: "DHC_COACH_TIER",
        student: "DHC_STUDENT_TIER"
      )

      :ok
    end

    test "is read-only and passes a standard invitation's coupon to the adapter" do
      invitation = insert_invitation!()
      {:ok, handle, _subject} = ready(invitation, "pricing-standard")

      assert {:ok, %{proratedPrice: %{amount: 0}}} = Acceptance.preview_pricing(handle, "WELCOME")
      assert_received {:preview_membership, "WELCOME"}
      assert {:ok, %{state: "paymentReady"}} = Acceptance.view(handle)
      refute_received {:prepare_payment, _}
    end

    test "a student tier resolves its coupon and ignores the user-supplied code" do
      invitation = insert_invitation!(pricing_tier: "student")
      {:ok, handle, _subject} = ready(invitation, "pricing-student")

      assert {:ok, _pricing} = Acceptance.preview_pricing(handle, "USER-SUPPLIED")
      assert_received {:preview_membership, {:coupon, "DHC_STUDENT_TIER", [:monthly]}}
    end

    test "a coach tier is complimentary without touching Stripe" do
      invitation = insert_invitation!(pricing_tier: "coach")
      {:ok, handle, _subject} = ready(invitation, "pricing-coach")

      assert {:ok, %{complimentary: true}} = Acceptance.preview_pricing(handle)
      refute_received {:preview_membership, _}
    end

    test "is available only in paymentReady: neither before proof consumption nor once payment started" do
      unconsumed = insert_invitation!()
      {:ok, unconsumed_handle, _subject} = verified(unconsumed, "pricing-unconsumed")
      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(unconsumed_handle)

      stalled = insert_invitation!()
      {:ok, stalled_handle, _subject} = ready(stalled, "pricing-stalled")
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})

      assert {:error, {:provider_unavailable, _}} =
               Acceptance.submit_payment(stalled_handle, @payment)

      flush_stripe_messages()
      assert {:ok, %{state: "paymentPending"}} = Acceptance.view(stalled_handle)
      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(stalled_handle)
      refute_received {:preview_membership, _}
    end

    test "an Invitation id is not a handle and a session before Discord cannot be priced" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = open(invitation)

      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(invitation.id)
      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(handle)
      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(Ecto.UUID.generate())
      assert {:error, :invalid_continuation} = Acceptance.preview_pricing("nope")
      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(nil)
      refute_received {:preview_membership, _}
    end

    test "an expired or cancelled session cannot be priced" do
      expired = insert_invitation!()
      {:ok, expired_handle, _} = verified(expired, "pricing-expired")
      expire_continuation!(expired_handle)

      cancelled = insert_invitation!()
      {:ok, cancelled_handle, _} = verified(cancelled, "pricing-cancelled")
      {:ok, _view} = Acceptance.cancel_discord(cancelled_handle)

      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(expired_handle)
      assert {:error, :invalid_continuation} = Acceptance.preview_pricing(cancelled_handle)
      refute_received {:preview_membership, _}
    end
  end

  # ── Payment ──────────────────────────────────────────────────────────

  describe "submit_payment/2" do
    test "finalizes a paid Discord-bound Member atomically and redacts every secret" do
      invitation = insert_invitation!()
      email = invitation.email

      {:ok, handle, _view} =
        verified(invitation, "paid-subject", %{
          "access_token" => "discord-join-token",
          "expires_in" => 604_800
        })

      assert {:ok, %{state: "paymentReady"}} = Acceptance.consume_proof(handle)

      assert {:ok, %{state: "accepted", invitation_email: ^email} = view} =
               Acceptance.submit_payment(handle, %{@payment | confirmation_token: "ctok_paid"})

      assert_safe(view)
      assert_received {:prepare_payment, nil}
      assert_received {:create_customer, %{attempt_id: attempt_id}}

      assert_received {:provision_membership,
                       %{
                         confirmation_token: "ctok_paid",
                         mandate_context: %{ip_address: "127.0.0.1", user_agent: "test-agent"}
                       }}

      principal_id = invitation.prospective_principal_id
      assert %Principal{email: ^email} = Repo.get!(Principal, principal_id)

      assert %UserProfile{customer_id: "cus_onboarding"} =
               Repo.get_by!(UserProfile, principal_id: principal_id)

      assert %MemberProfile{next_of_kin_name: "Grace Hopper"} =
               Repo.get!(MemberProfile, principal_id)

      assert %UserRole{role: "member"} = Repo.get_by!(UserRole, principal_id: principal_id)

      assert %ExternalIdentity{provider_subject: "paid-subject", metadata: %{"username" => _}} =
               Repo.get_by!(ExternalIdentity, principal_id: principal_id, provider: "discord")

      attempt = Repo.get!(InvitationAcceptanceAttempt, attempt_id)
      assert attempt.status == "completed"
      assert attempt.operation_token == nil
      refute Map.has_key?(attempt.acceptance_data, "payment")

      grant = Repo.get_by!(JoinGrant, attempt_id: attempt_id)
      assert_enqueued(worker: GuildJoinWorker, args: %{"grant_id" => grant.id})
      refute inspect(all_enqueued(worker: GuildJoinWorker)) =~ "discord-join-token"

      assert %InvitationAcceptanceDiscordContinuation{status: "consumed", provider_subject: nil} =
               Repo.get!(InvitationAcceptanceDiscordContinuation, handle)

      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      refute Repo.exists?(PrincipalToken)
      assert Repo.get!(Invitation, invitation.id).status == "accepted"
    end

    test "duplicate submissions reuse the durable input and make no further provider call" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "duplicate-submit")

      assert {:ok, %{state: "accepted"}} = Acceptance.submit_payment(handle, @payment)
      flush_stripe_messages()

      assert {:ok, %{state: "accepted"}} =
               Acceptance.submit_payment(handle, %{
                 @payment
                 | next_of_kin_name: "Must not replace durable input",
                   confirmation_token: "ctok_must_not_be_used"
               })

      refute_received {:prepare_payment, _}
      refute_received {:create_customer, _}
      refute_received {:provision_membership, _}
      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1

      assert Repo.get_by!(MemberProfile, next_of_kin_name: "Grace Hopper")
    end

    test "a stalled submission keeps its original Stripe input across retries" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "retry-subject")
      timeout = {:http_error, :timeout}
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, timeout})

      original = %{@payment | confirmation_token: "ctok_original", coupon_code: "WELCOME"}

      assert {:error, {:provider_unavailable, ^timeout}} =
               Acceptance.submit_payment(handle, original)

      assert_received {:prepare_payment, "WELCOME"}
      assert_received {:create_customer, _}
      assert_received {:provision_membership, %{confirmation_token: "ctok_original"}}

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "payment_pending"
      assert attempt.operation_token == nil
      assert attempt.last_error == "http_error"
      assert_enqueued(worker: AcceptanceRecoveryWorker, args: %{"attempt_id" => attempt.id})
      jobs = all_enqueued(worker: AcceptanceRecoveryWorker)
      refute inspect(jobs) =~ "ctok_original"
      refute inspect(jobs) =~ "retry-subject"

      assert {:ok, %{state: "paymentPending", discord_verified: true, retry_allowed: true} = view} =
               Acceptance.view(handle)

      assert_safe(view)
      Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

      # A duplicate submission does not resume Stripe: only an explicit retry does.
      assert {:ok, %{state: "paymentPending"}} =
               Acceptance.submit_payment(handle, %{
                 original
                 | confirmation_token: "ctok_changed",
                   coupon_code: "CHANGED",
                   next_of_kin_name: "Updated Kin"
               })

      refute_received {:provision_membership, _}

      assert {:ok, %{state: "accepted"}} = Acceptance.retry(handle)
      refute_received {:prepare_payment, "CHANGED"}

      assert_received {:provision_membership,
                       %{confirmation_token: "ctok_original", coupon_code: "WELCOME"}}

      attempt = Repo.get!(InvitationAcceptanceAttempt, attempt.id)
      assert attempt.status == "completed"
      assert attempt.acceptance_data["next_of_kin_name"] == "Grace Hopper"
      assert attempt.stripe_state["payment_plan"]["promotion_code_id"] == "promo_onboarding"
    end

    test "a second submission while the lease is active makes no provider call" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "leased-subject")
      test_pid = self()

      Application.put_env(:dhc, :onboarding_stripe_result, fn ->
        send(test_pid, {:stripe_progression_started, self()})

        receive do
          :release -> {:ok, %{}}
        end
      end)

      owner =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
          Acceptance.submit_payment(handle, @payment)
        end)

      assert_receive {:stripe_progression_started, stripe_pid}, 5_000
      flush_stripe_messages()

      assert {:ok, %{state: "paymentPending", retry_allowed: false}} =
               Acceptance.submit_payment(handle, %{@payment | confirmation_token: "ctok_second"})

      assert {:error, :retry_not_allowed} = Acceptance.retry(handle)
      refute_received {:provision_membership, _}

      send(stripe_pid, :release)
      assert {:ok, %{state: "accepted"}} = Task.await(owner)
      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    end

    test "rejects incomplete details and unconsumed proofs before touching Stripe" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "unready-subject")

      assert {:error, :invalid_acceptance_details} =
               Acceptance.submit_payment(handle, %{@payment | next_of_kin_name: " "})

      assert {:error, :invalid_acceptance_details} =
               Acceptance.submit_payment(handle, Map.delete(@payment, :confirmation_token))

      assert {:error, :invalid_continuation} = Acceptance.submit_payment(handle, @payment)
      assert {:error, :invalid_continuation} = Acceptance.submit_payment("junk", @payment)
      refute_received {:prepare_payment, _}
      refute_received {:create_customer, _}
    end

    test "resolves the invitation tier before preparing Stripe" do
      Application.put_env(:dhc, :membership_tier_coupons, student: "DHC_STUDENT_TIER")
      invitation = insert_invitation!(pricing_tier: "student")
      {:ok, handle, _view} = ready(invitation, "student-subject")

      assert {:ok, %{state: "accepted"}} =
               Acceptance.submit_payment(handle, %{@payment | coupon_code: "MUST-NOT-WIN"})

      assert_received {:prepare_payment, {:coupon, "DHC_STUDENT_TIER", [:monthly]}}

      assert_received {:provision_membership,
                       %{
                         payment_plan: %{
                           coupon_id: "DHC_STUDENT_TIER",
                           discount_targets: [:monthly],
                           promotion_code_id: nil
                         }
                       }}
    end

    test "a coach tier is complimentary and needs no confirmation token" do
      Application.put_env(:dhc, :membership_tier_coupons, coach: "DHC_COACH_TIER")
      invitation = insert_invitation!(pricing_tier: "coach")
      {:ok, handle, _view} = ready(invitation, "coach-subject")

      assert {:ok, %{state: "paymentReady", complimentary: true}} = Acceptance.view(handle)

      assert {:ok, %{state: "accepted"}} =
               Acceptance.submit_payment(handle, Map.delete(@payment, :confirmation_token))

      assert_received {:prepare_payment, {:coupon, "DHC_COACH_TIER", [:monthly, :annual]}}
      assert_received {:create_customer, _}
      assert_received {:provision_membership, %{complimentary: true}}
      assert Repo.get!(Invitation, invitation.id).status == "accepted"
    end

    test "a misconfigured tier coupon releases the lease without recording a provider failure" do
      Application.put_env(:dhc, :membership_tier_coupons, coach: "DHC_COACH_TIER")

      Application.put_env(
        :dhc,
        :onboarding_stripe_prepare_result,
        {:error, :tier_coupon_not_configured}
      )

      invitation = insert_invitation!(pricing_tier: "coach")
      {:ok, handle, _view} = ready(invitation, "coach-misconfig")

      assert {:error, :tier_coupon_not_configured} = Acceptance.submit_payment(handle, @payment)

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "payment_pending"
      assert is_nil(attempt.operation_token)
      assert attempt.last_error == "tier_coupon_not_configured"
      refute_received {:create_customer, _}
      refute_received {:provision_membership, _}

      assert {:cancel, :tier_coupon_not_configured} =
               perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
    end

    test "a processing SEPA PaymentIntent finalizes while settlement remains pending" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "sepa-subject")

      stripe_state = %{"payment_state" => "pending", "payment_intent_status" => "processing"}
      Application.put_env(:dhc, :onboarding_stripe_result, {:pending, stripe_state})

      assert {:ok, %{state: "accepted"}} = Acceptance.submit_payment(handle, @payment)

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "completed"
      assert Map.take(attempt.stripe_state, Map.keys(stripe_state)) == stripe_state
      assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
    end

    test "incomplete PaymentIntent outcomes stay durable without converting the Invitation" do
      outcomes = [
        {%{"payment_state" => "needs_action", "payment_intent_status" => "requires_action"},
         "paymentNeedsAction"},
        {%{"payment_state" => "terminal", "payment_intent_status" => "canceled"},
         "paymentTerminal"}
      ]

      for {stripe_state, expected_state} <- outcomes do
        invitation = insert_invitation!()
        {:ok, handle, _view} = ready(invitation, expected_state)
        Application.put_env(:dhc, :onboarding_stripe_result, {:pending, stripe_state})

        assert {:ok, %{state: ^expected_state} = view} =
                 Acceptance.submit_payment(handle, @payment)

        assert_safe(view)
        assert {:ok, %{state: ^expected_state}} = Acceptance.view(handle)

        attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
        assert attempt.status == "payment_pending"
        assert Map.take(attempt.stripe_state, Map.keys(stripe_state)) == stripe_state
        assert Repo.get!(Invitation, invitation.id).status == "pending"
        refute Repo.get(Principal, invitation.prospective_principal_id)
      end
    end

    test "a terminal payment failure cleans up Stripe, releases the proof, and allows a fresh session" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "declined-subject")
      decline = {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, decline})

      Application.put_env(:dhc, :onboarding_stripe_progress, %{
        "monthly_subscription_id" => "sub_monthly_onboarding",
        "monthly_confirmed" => true,
        "annual_subscription_id" => "sub_annual_onboarding"
      })

      assert {:error, {:payment_failed, ^decline}} = Acceptance.submit_payment(handle, @payment)

      assert_received {:cancel_membership,
                       %{
                         "monthly_subscription_id" => "sub_monthly_onboarding",
                         "monthly_confirmed" => true,
                         "annual_subscription_id" => "sub_annual_onboarding",
                         "customer_id" => "cus_onboarding"
                       }}

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "declined"
      assert attempt.last_error == "stripe:402:card_declined"
      assert attempt.stripe_customer_id == "cus_onboarding"
      refute Map.has_key?(attempt.acceptance_data, "payment")

      assert %InvitationAcceptanceDiscordContinuation{
               status: "failed",
               provider_subject: nil,
               subject_fingerprint: nil,
               display_metadata: %{}
             } = Repo.get!(InvitationAcceptanceDiscordContinuation, handle)

      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      assert {:ok, %{state: "restartVerification"}} = Acceptance.view(handle)
      assert Repo.get!(Invitation, invitation.id).status == "pending"

      Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
      Application.delete_env(:dhc, :onboarding_stripe_progress)
      {:ok, fresh_handle, _view} = ready(invitation, "declined-subject-again")
      refute fresh_handle == handle

      assert {:ok, %{state: "accepted"}} = Acceptance.submit_payment(fresh_handle, @payment)

      attempts =
        Repo.all(
          from(a in InvitationAcceptanceAttempt,
            where: a.invitation_id == ^invitation.id,
            order_by: [asc: a.created_at]
          )
        )

      assert Enum.map(attempts, & &1.status) == ["declined", "completed"]
      # The prior Stripe customer is carried into the fresh Attempt.
      assert Enum.map(attempts, & &1.stripe_customer_id) == ["cus_onboarding", "cus_onboarding"]
    end

    test "a live-shaped Stripe customer rejection closes the Attempt before any provisioning" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "customer-declined")
      decline = {:stripe_customer, {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}}
      Application.put_env(:dhc, :onboarding_stripe_customer_result, {:error, decline})

      assert {:error, {:payment_failed, ^decline}} = Acceptance.submit_payment(handle, @payment)
      refute_received {:provision_membership, _}

      assert %InvitationAcceptanceAttempt{status: "declined", concluded_at: %DateTime{}} =
               Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    end

    test "cleanup succeeds when the Attempt failed before its Stripe customer existed" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "no-customer")

      # Regression for the 2026-08-24 coach-invitation incident: a failure before
      # customer creation used to poison cleanup with an empty Stripe customer.
      Application.put_env(
        :dhc,
        :onboarding_stripe_customer_result,
        {:error, {:stripe_api, 400, %{"error" => %{"code" => "parameter_invalid_empty"}}}}
      )

      assert {:error, {:payment_failed, {:stripe_api, 400, _body}}} =
               Acceptance.submit_payment(handle, @payment)

      assert_received {:cancel_membership, %{"customer_id" => nil, "acceptance_attempt_id" => id}}
      attempt = Repo.get!(InvitationAcceptanceAttempt, id)
      assert attempt.status == "declined"
      assert is_nil(attempt.stripe_customer_id)
      assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
    end

    test "a retryable Stripe rate limit keeps the Attempt available for retry" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "rate-limited")
      rate_limit = {:stripe_api, 429, %{"error" => %{"code" => "rate_limit"}}}
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, rate_limit})

      assert {:error, {:provider_unavailable, ^rate_limit}} =
               Acceptance.submit_payment(handle, @payment)

      assert %InvitationAcceptanceAttempt{status: "payment_pending", concluded_at: nil} =
               Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

      Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
      assert {:ok, %{state: "accepted"}} = Acceptance.retry(handle)
      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    end

    test "a consumed proof resumes its Attempt after both the Invitation and session expire" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "late-resume")
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})

      assert {:error, {:provider_unavailable, _}} = Acceptance.submit_payment(handle, @payment)

      expire_invitation!(invitation)
      expire_continuation!(handle)
      Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

      assert {:ok, %{state: "paymentPending", retry_allowed: true}} = Acceptance.view(handle)
      assert {:ok, %{state: "accepted"}} = Acceptance.retry(handle)

      assert %InvitationAcceptanceAttempt{status: "completed"} =
               Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
    end

    test "waitlist acceptance reuses the intake UserProfile and keeps its guardian" do
      invitation =
        insert_waitlist_invitation!(
          gender: "non-binary",
          pronouns: "they/them",
          phone_number: "+353871234567",
          social_media_consent: "yes_recognizable",
          medical_conditions: "asthma",
          guardian: true
        )

      profile = Repo.get_by!(UserProfile, waitlist_id: invitation.waitlist_id)
      {:ok, handle, _view} = ready(invitation, "waitlist-subject")

      assert {:ok, %{state: "accepted"}} = Acceptance.submit_payment(handle, @payment)

      assert [reused] =
               Repo.all(from(up in UserProfile, where: up.waitlist_id == ^invitation.waitlist_id))

      assert reused.id == profile.id
      assert reused.principal_id == invitation.prospective_principal_id
      assert reused.is_active
      assert reused.customer_id == "cus_onboarding"
      assert reused.gender == "non-binary"
      assert reused.medical_conditions == "asthma"

      assert Repo.get!(MemberProfile, invitation.prospective_principal_id).user_profile_id ==
               reused.id

      assert [["Parent", "Guardian"]] =
               Repo.query!(
                 "SELECT first_name, last_name FROM waitlist_guardians WHERE profile_id = $1",
                 [Ecto.UUID.dump!(profile.id)]
               ).rows
    end
  end

  # ── Finalization races and recovery ──────────────────────────────────

  describe "finalization and recovery" do
    test "a finalization rollback leaves no partial Member identity and stays recoverable" do
      invitation = insert_invitation!()

      {:ok, handle, _view} =
        ready(invitation, "rollback-subject", %{
          "access_token" => "rollback-join-token",
          "expires_in" => 604_800
        })

      conflicting = Repo.insert!(%Principal{id: Ecto.UUID.generate(), email: invitation.email})

      assert {:error, :principal_creation_failed} = Acceptance.submit_payment(handle, @payment)
      flush_stripe_messages()

      principal_id = invitation.prospective_principal_id
      refute Repo.get(Principal, principal_id)
      refute Repo.get(MemberProfile, principal_id)
      refute Repo.get_by(UserProfile, principal_id: principal_id)
      refute Repo.get_by(ExternalIdentity, provider_subject: "rollback-subject")
      refute Repo.get_by(UserRole, principal_id: principal_id)
      refute_enqueued(worker: GuildJoinWorker)
      assert Repo.get!(Invitation, invitation.id).status == "pending"

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "provisioned"
      assert attempt.operation_token == nil
      assert attempt.last_error == "local_finalization_failed"
      assert Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      assert_enqueued(worker: AcceptanceRecoveryWorker, args: %{"attempt_id" => attempt.id})

      assert {:ok, %{state: "paymentPending", retry_allowed: true}} = Acceptance.view(handle)

      Repo.delete!(conflicting)
      expire_invitation!(invitation)

      assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
      refute_received {:provision_membership, _}

      grant = Repo.get_by!(JoinGrant, attempt_id: attempt.id)
      assert_enqueued(worker: GuildJoinWorker, args: %{"grant_id" => grant.id})

      assert Repo.get_by!(ExternalIdentity, principal_id: principal_id).provider_subject ==
               "rollback-subject"

      assert Repo.get!(InvitationAcceptanceDiscordContinuation, handle).status == "consumed"
      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      assert {:ok, %{state: "accepted"}} = Acceptance.view(handle)
    end

    test "repeated finalization returns the accepted view without duplicate rows" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "repeat-finalize")

      assert {:ok, %{state: "accepted"}} = Acceptance.submit_payment(handle, @payment)
      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

      assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
      assert {:ok, %{state: "accepted"}} = Acceptance.submit_payment(handle, @payment)
      assert {:error, :retry_not_allowed} = Acceptance.retry(handle)

      principal_id = invitation.prospective_principal_id
      assert Repo.aggregate(from(p in Principal, where: p.id == ^principal_id), :count) == 1
      assert Repo.aggregate(from(m in MemberProfile, where: m.id == ^principal_id), :count) == 1

      assert Repo.aggregate(from(r in UserRole, where: r.principal_id == ^principal_id), :count) ==
               1

      assert Repo.aggregate(
               from(e in ExternalIdentity, where: e.principal_id == ^principal_id),
               :count
             ) == 1
    end

    test "failed Stripe cleanup is retried by recovery before the Attempt concludes" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "cleanup-retry")
      decline = {:stripe_api, 402, %{"error" => %{"code" => "card_declined"}}}
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, decline})
      Application.put_env(:dhc, :onboarding_stripe_cancel_result, {:error, :stripe_unavailable})

      assert {:error, {:payment_failed, ^decline}} = Acceptance.submit_payment(handle, @payment)

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "cleanup_pending"
      assert attempt.last_error == "stripe_cleanup_unavailable"
      assert_enqueued(worker: AcceptanceRecoveryWorker, args: %{"attempt_id" => attempt.id})

      # The browser can neither resubmit nor retry while cleanup is owed.
      assert {:error, :invalid_continuation} = Acceptance.submit_payment(handle, @payment)
      assert {:error, :retry_not_allowed} = Acceptance.retry(handle)
      assert {:error, :invalid_invitation} = open(invitation)

      assert {:error, :stripe_unavailable} =
               perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})

      Application.put_env(:dhc, :onboarding_stripe_cancel_result, :ok)
      assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
      assert Repo.get!(InvitationAcceptanceAttempt, attempt.id).status == "declined"
      assert Repo.get!(InvitationAcceptanceDiscordContinuation, handle).status == "failed"
      assert {:ok, _fresh, %{state: "awaiting_oauth"}} = open(invitation)
    end

    test "recovery from payment_pending completes the acceptance" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "recover-payment")
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})
      assert {:error, {:provider_unavailable, _}} = Acceptance.submit_payment(handle, @payment)
      Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})

      assert Repo.get!(InvitationAcceptanceAttempt, attempt.id).status == "completed"
      assert Repo.get!(Invitation, invitation.id).status == "accepted"
    end

    test "recovery for unknown, unstarted, and legacy Attempts cancels instead of retrying" do
      assert {:cancel, :attempt_not_found} =
               perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => Ecto.UUID.generate()})

      assert {:cancel, :attempt_not_found} =
               perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => "junk"})

      invitation = insert_invitation!()
      {:ok, _handle, _view} = open(invitation)
      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

      assert {:cancel, :payment_not_started} =
               perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})

      legacy =
        Repo.insert!(%InvitationAcceptanceAttempt{
          invitation_id: insert_invitation!().id,
          status: "payment_pending",
          acceptance_data: %{"next_of_kin_name" => "Legacy", "next_of_kin_phone" => "+1"}
        })

      assert {:cancel, :legacy_attempt} =
               perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => legacy.id})
    end

    test "a stale operation cannot write Stripe progress or provision" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "stale-operation")
      test_pid = self()

      # The adapter reports progress after the lease has been stolen: the stale
      # callback must be rejected and the fresh owner must win.
      Application.put_env(:dhc, :onboarding_stripe_result, fn ->
        attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

        attempt
        |> Ecto.Changeset.change(operation_token: Ecto.UUID.generate())
        |> Repo.update!()

        send(test_pid, :lease_stolen)
        {:ok, %{"late" => true}}
      end)

      assert {:error, :stale_acceptance_operation} = Acceptance.submit_payment(handle, @payment)
      assert_received :lease_stolen

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      assert attempt.status == "payment_pending"
      refute Map.has_key?(attempt.stripe_state, "late")
      assert Repo.get!(Invitation, invitation.id).status == "pending"
      refute Repo.get(Principal, invitation.prospective_principal_id)
    end

    test "webhook reconciliation racing synchronous completion does not convert twice" do
      Application.put_env(:dhc, :acceptance_recovery_delay_seconds, 1)
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "webhook-race")

      assert {:ok, %{state: "accepted"}} = Acceptance.submit_payment(handle, @payment)
      flush_stripe_messages()
      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)

      assert :ok =
               StripeWebhooks.process_event(%{
                 "type" => "account.updated",
                 "data" => %{"object" => %{"id" => "acct_race", "customer" => "cus_onboarding"}}
               })

      assert :ok = perform_job(AcceptanceRecoveryWorker, %{"attempt_id" => attempt.id})
      refute_received {:provision_membership, %{confirmation_token: "ctok_success"}}

      principal_id = invitation.prospective_principal_id
      assert Repo.aggregate(from(p in Principal, where: p.id == ^principal_id), :count) == 1
      assert Repo.aggregate(from(m in MemberProfile, where: m.id == ^principal_id), :count) == 1
      assert Repo.aggregate(InvitationAcceptanceAttempt, :count) == 1
    end

    test "Stripe reconciliation advances one unique scheduled recovery per Attempt" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "reconcile-subject")
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})
      assert {:error, {:provider_unavailable, _}} = Acceptance.submit_payment(handle, @payment)

      attempt = Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id)
      args = %{"attempt_id" => attempt.id}

      assert [%{id: job_id, scheduled_at: first_scheduled_at}] =
               all_enqueued(worker: AcceptanceRecoveryWorker)

      # A webhook brings the scheduled recovery forward instead of adding a job.
      Application.put_env(:dhc, :acceptance_recovery_delay_seconds, 1)

      for {customer, index} <- Enum.with_index(["cus_onboarding", %{"id" => "cus_onboarding"}]) do
        assert :ok =
                 StripeWebhooks.process_event(%{
                   "type" => "account.updated",
                   "data" => %{"object" => %{"id" => "acct_#{index}", "customer" => customer}}
                 })
      end

      assert [%{id: ^job_id, args: ^args, scheduled_at: scheduled_at}] =
               all_enqueued(worker: AcceptanceRecoveryWorker)

      assert DateTime.before?(scheduled_at, first_scheduled_at)
      assert :ok = Acceptance.reconcile_stripe_event(%{"customer" => "cus_unknown"})
      assert :ok = Acceptance.reconcile_stripe_event(%{})
    end
  end

  # ── Expiry sweep ─────────────────────────────────────────────────────

  describe "expire_continuations/0" do
    test "preserves a consumed proof while payment remains recoverable" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = ready(invitation, "recoverable-subject")
      Application.put_env(:dhc, :onboarding_stripe_result, {:error, {:http_error, :timeout}})
      assert {:error, {:provider_unavailable, _}} = Acceptance.submit_payment(handle, @payment)
      expire_continuation!(handle)

      assert :ok = perform_job(DiscordContinuationExpiryWorker, %{})

      assert %InvitationAcceptanceDiscordContinuation{
               status: "verified",
               provider_subject: "recoverable-subject"
             } = Repo.get!(InvitationAcceptanceDiscordContinuation, handle)

      assert Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: invitation.id).status ==
               "payment_pending"

      assert Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
    end

    test "reports inconsistent Claims without deleting evidence" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "inconsistent-subject")
      expire_continuation!(handle)

      claim = Repo.one!(InvitationAcceptanceDiscordSubjectClaim)
      Repo.query!("SET CONSTRAINTS ALL DEFERRED")
      claim |> Ecto.Changeset.change(provider_subject: "mismatched-subject") |> Repo.update!()

      assert {:error, {:inconsistent_claims, [^handle]}} =
               DiscordContinuationExpiryWorker.perform(%Oban.Job{args: %{}})

      assert Repo.get!(InvitationAcceptanceDiscordContinuation, handle).status == "verified"
      assert Repo.get!(InvitationAcceptanceDiscordSubjectClaim, claim.id)
    end

    test "uses the injected clock and is idempotent" do
      invitation = insert_invitation!()
      {:ok, handle, _view} = verified(invitation, "clock-subject")
      continuation = Repo.get!(InvitationAcceptanceDiscordContinuation, handle)
      future = DateTime.add(continuation.expires_at, 1, :second)
      Application.put_env(:dhc, :onboarding_acceptance_clock, fn -> future end)

      assert {:ok, 1} = Acceptance.expire_continuations()
      assert {:ok, 0} = Acceptance.expire_continuations()
      assert Repo.get!(InvitationAcceptanceDiscordContinuation, handle).status == "expired"
      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
    end

    test "expiry and recovery jobs enqueue uniquely without sensitive arguments" do
      assert {:ok, _job} = Oban.insert(DiscordContinuationExpiryWorker.new(%{}))
      assert {:ok, _same} = Oban.insert(DiscordContinuationExpiryWorker.new(%{}))
      assert [%{args: %{}}] = all_enqueued(worker: DiscordContinuationExpiryWorker)

      args = %{"attempt_id" => Ecto.UUID.generate()}
      assert {:ok, _job} = Oban.insert(AcceptanceRecoveryWorker.new(args))
      assert {:ok, _same} = Oban.insert(AcceptanceRecoveryWorker.new(args))
      assert [%{args: ^args}] = all_enqueued(worker: AcceptanceRecoveryWorker)
    end
  end

  test "credential verification is fenced once a protected session exists" do
    invitation = insert_invitation!()
    assert :ok = Onboarding.verify_credentials(invitation.id, invitation.email, "1990-01-01")

    {:ok, _handle, _view} = open(invitation)

    assert {:error, :invalid_credentials} =
             Onboarding.verify_credentials(invitation.id, invitation.email, "1990-01-01")
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp open(invitation, existing_handle \\ nil) do
    Acceptance.open(
      invitation.id,
      invitation.email,
      Date.to_iso8601(invitation.date_of_birth),
      existing_handle
    )
  end

  defp verified(invitation, subject, join_grant \\ nil) do
    {:ok, handle, _view} = open(invitation)

    {:ok, %{state: "discordVerified"}} =
      Acceptance.verify_discord(
        handle,
        %{"sub" => subject, "preferred_username" => subject},
        join_grant
      )

    {:ok, handle, subject}
  end

  defp ready(invitation, subject, join_grant \\ nil) do
    {:ok, handle, _subject} = verified(invitation, subject, join_grant)
    {:ok, %{state: "paymentReady"}} = Acceptance.consume_proof(handle)
    {:ok, handle, subject}
  end

  defp assert_safe(view) when is_map(view) do
    assert is_binary(view.state)

    for key <- @secret_keys do
      refute Map.has_key?(view, key), "safe view must not expose #{key}"
    end

    refute view |> inspect() |> String.contains?("ctok_")
  end

  defp flush_stripe_messages do
    receive do
      {tag, _payload}
      when tag in [:prepare_payment, :create_customer, :provision_membership, :preview_membership] ->
        flush_stripe_messages()
    after
      0 -> :ok
    end
  end

  defp invitation_of(handle),
    do: Repo.get!(InvitationAcceptanceDiscordContinuation, handle).invitation_id

  defp expire_continuation!(handle) do
    InvitationAcceptanceDiscordContinuation
    |> Repo.get!(handle)
    |> Ecto.Changeset.change(expires_at: seconds_ago(60))
    |> Repo.update!()
  end

  defp expire_invitation!(invitation) do
    invitation |> Ecto.Changeset.change(expires_at: seconds_ago(60)) |> Repo.update!()
  end

  defp seconds_ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  defp insert_invitation!(attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Invitation{
      email: "acceptance-#{System.unique_integer([:positive])}@example.com",
      prospective_principal_id: Ecto.UUID.generate(),
      status: "pending",
      expires_at: DateTime.add(now, 7, :day),
      invitation_type: "member",
      first_name: "Ada",
      last_name: "Lovelace",
      phone_number: "+353810000000",
      date_of_birth: ~D[1990-01-01]
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp insert_waitlist_invitation!(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    waitlist_id = Ecto.UUID.generate()

    Repo.insert!(%Dhc.Waitlist.WaitlistEntry{
      id: waitlist_id,
      email: "waitlist-acceptance-#{System.unique_integer([:positive])}@example.com",
      status: "invited",
      initial_registration_date: now,
      last_status_change: now
    })

    waitlist = Repo.get!(Dhc.Waitlist.WaitlistEntry, waitlist_id)
    profile_id = Ecto.UUID.generate()

    Repo.insert!(%UserProfile{
      id: profile_id,
      waitlist_id: waitlist_id,
      first_name: "IntakeFirst",
      last_name: "IntakeLast",
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

    Repo.insert!(%Invitation{
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
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:dhc, key)
  defp restore_env(key, value), do: Application.put_env(:dhc, key, value)
end
