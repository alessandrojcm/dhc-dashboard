defmodule Dhc.Onboarding.Ale213DiscordClaimConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.DiscordSubjectLock
  alias Dhc.Auth.{ExternalIdentity, Principal, PrincipalToken, UserRole}
  alias Dhc.Invitations.Invitation

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    AssignmentStageResult,
    RosterReceipt,
    StagedAssignment,
    StagedAssignmentAuditEvent
  }

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Onboarding
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordCollisionAuditEvent
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    original_adapter = Application.get_env(:dhc, :onboarding_stripe_adapter)
    original_result = Application.get_env(:dhc, :onboarding_stripe_result)
    original_customer_result = Application.get_env(:dhc, :onboarding_stripe_customer_result)
    original_test_pid = Application.get_env(:dhc, :onboarding_test_pid)
    test_pid = self()

    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.OnboardingTestStripeAdapter)
    Application.put_env(:dhc, :onboarding_stripe_customer_result, {:ok, "cus_concurrency"})
    Application.put_env(:dhc, :onboarding_test_pid, test_pid)

    Application.put_env(:dhc, :onboarding_stripe_result, fn ->
      send(test_pid, {:stripe_progression_started, Process.get(:acceptance_label), self()})

      receive do
        :release_stripe_progression -> {:ok, %{}}
      end
    end)

    on_exit(fn ->
      restore_env(:onboarding_stripe_adapter, original_adapter)
      restore_env(:onboarding_stripe_result, original_result)
      restore_env(:onboarding_stripe_customer_result, original_customer_result)
      restore_env(:onboarding_test_pid, original_test_pid)
    end)
  end

  test "the first request owns Stripe progression while its duplicate observes in-progress state" do
    assert_single_stripe_progression(:first)
  end

  test "the second request owns Stripe progression while the first observes in-progress state" do
    assert_single_stripe_progression(:second)
  end

  test "concurrent acceptances reserve a Discord subject exactly once" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    acceptances = unboxed(fn -> [acceptance_fixture(), acceptance_fixture()] end)
    continuation_ids = Enum.map(acceptances, & &1.continuation_id)
    invitation_ids = Enum.map(acceptances, & &1.invitation_id)

    on_exit(fn -> unboxed(fn -> delete_acceptances(invitation_ids) end) end)

    claims = %{
      "sub" => unique_subject("same-subject"),
      "preferred_username" => "same-account"
    }

    [first_id, second_id] = continuation_ids

    first =
      ready_task(task_supervisor, test_process, :first, fn ->
        Onboarding.verify_discord(first_id, claims)
      end)

    second =
      ready_task(task_supervisor, test_process, :second, fn ->
        Onboarding.verify_discord(second_id, claims)
      end)

    assert_receive {:ready, :first, first_pid}
    assert_receive {:ready, :second, second_pid}
    send(first_pid, :go)
    send(second_pid, :go)

    results = [Task.await(first), Task.await(second)]

    assert Enum.count(results, &match?({:ok, %{state: "discordVerified"}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :collision}, &1)) == 1

    unboxed(fn ->
      assert Repo.aggregate(
               from(c in InvitationAcceptanceDiscordSubjectClaim,
                 where: c.continuation_id in ^continuation_ids
               ),
               :count
             ) == 1

      statuses =
        Repo.all(
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.id in ^continuation_ids,
            select: c.status
          )
        )

      assert Enum.sort(statuses) == ["collision", "verified"]
    end)
  end

  test "a transient claim and permanent Discord link cannot win the same subject race" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    %{acceptance: acceptance, member: member} =
      unboxed(fn ->
        %{
          acceptance: acceptance_fixture(),
          member: Dhc.MemberFixtures.member_fixture(is_active: true)
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        delete_acceptances([acceptance.invitation_id])
        delete_member(member.principal_id)
      end)
    end)

    subject = unique_subject("claim-link")
    claims = %{"sub" => subject, "preferred_username" => "racing-account"}

    acceptance_task =
      ready_task(task_supervisor, test_process, :acceptance, fn ->
        Onboarding.verify_discord(acceptance.continuation_id, claims)
      end)

    link_task =
      ready_task(task_supervisor, test_process, :link, fn ->
        Auth.link_discord_identity(member.principal_id, claims)
      end)

    assert_receive {:ready, :acceptance, acceptance_pid}
    assert_receive {:ready, :link, link_pid}
    send(acceptance_pid, :go)
    send(link_pid, :go)

    acceptance_result = Task.await(acceptance_task)
    link_result = Task.await(link_task)

    case {acceptance_result, link_result} do
      {{:ok, %{state: "discordVerified"}}, {:error, :invalid}} -> :ok
      {{:error, :collision}, {:ok, %ExternalIdentity{}}} -> :ok
      results -> flunk("expected one Discord binding winner, got: #{inspect(results)}")
    end

    unboxed(fn ->
      claim_count =
        Repo.aggregate(
          from(c in InvitationAcceptanceDiscordSubjectClaim,
            where: c.provider == "discord" and c.provider_subject == ^subject
          ),
          :count
        )

      identity_count =
        Repo.aggregate(
          from(i in ExternalIdentity,
            where: i.provider == "discord" and i.provider_subject == ^subject
          ),
          :count
        )

      assert claim_count + identity_count == 1

      refute Repo.exists?(
               from(t in PrincipalToken, where: t.principal_id == ^member.principal_id)
             )
    end)
  end

  test "Claim versus promotion overlaps at the subject lock in both queue orders" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    for order <- [[:promotion, :claim], [:claim, :promotion]] do
      %{acceptance: acceptance, target: target, assignment: assignment, subject: subject} =
        unboxed(fn ->
          acceptance = acceptance_fixture()
          target = Dhc.MemberFixtures.member_fixture(is_active: true)
          subject = unique_subject("claim-promotion-#{Enum.join(order, "-")}")

          %{
            acceptance: acceptance,
            target: target,
            subject: subject,
            assignment:
              Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(
                target.principal_id,
                subject
              )
          }
        end)

      on_exit(fn ->
        unboxed(fn ->
          delete_acceptances([acceptance.invitation_id])
          delete_assignment_fixture(assignment)
        end)
      end)

      results =
        subject_lock_race(task_supervisor, test_process, subject, order, %{
          promotion: fn -> Auth.sign_in_with_discord(%{"sub" => subject}) end,
          claim: fn ->
            Onboarding.verify_discord(acceptance.continuation_id, %{"sub" => subject})
          end
        })

      assert {:ok, %{principal: %{id: principal_id}}} = results.promotion
      assert principal_id == target.principal_id
      assert {:error, :collision} = results.claim

      unboxed(fn ->
        assert Repo.get!(StagedAssignment, assignment.id).state == "promoted"
        assert Repo.get_by!(ExternalIdentity, provider: "discord", provider_subject: subject)
        refute Repo.get_by(InvitationAcceptanceDiscordSubjectClaim, provider_subject: subject)
      end)
    end
  end

  test "duplicate promotions converge on one identity and one promotion audit" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    %{target: target, assignment: assignment, subject: subject} =
      unboxed(fn ->
        target = Dhc.MemberFixtures.member_fixture(is_active: true)
        subject = unique_subject("duplicate-promotion")

        %{
          target: target,
          subject: subject,
          assignment:
            Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(
              target.principal_id,
              subject
            )
        }
      end)

    on_exit(fn -> unboxed(fn -> delete_assignment_fixture(assignment) end) end)

    results =
      subject_lock_race(
        task_supervisor,
        test_process,
        subject,
        [:first_promotion, :second_promotion],
        %{
          first_promotion: fn -> Auth.sign_in_with_discord(%{"sub" => subject}) end,
          second_promotion: fn -> Auth.sign_in_with_discord(%{"sub" => subject}) end
        }
      )

    assert Enum.all?(results, fn {_label, result} ->
             match?({:ok, %{principal: %{id: id}}} when id == target.principal_id, result)
           end)

    unboxed(fn ->
      assert Repo.aggregate(
               from(i in ExternalIdentity,
                 where: i.provider == "discord" and i.provider_subject == ^subject
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(e in StagedAssignmentAuditEvent,
                 where: e.assignment_id == ^assignment.id and e.action == "promoted"
               ),
               :count
             ) == 1

      assert Repo.get!(StagedAssignment, assignment.id).state == "promoted"
    end)
  end

  test "promotion versus permanent link overlaps at the subject lock in both queue orders" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    for order <- [
          [:assignment_promotion, :permanent_link],
          [:permanent_link, :assignment_promotion]
        ] do
      %{target: target, contender: contender, assignment: assignment, subject: subject} =
        unboxed(fn ->
          target = Dhc.MemberFixtures.member_fixture(is_active: true)
          contender = Dhc.MemberFixtures.member_fixture(is_active: true)
          subject = unique_subject("permanent-collision-#{Enum.join(order, "-")}")

          %{
            target: target,
            contender: contender,
            subject: subject,
            assignment:
              Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(
                target.principal_id,
                subject
              )
          }
        end)

      on_exit(fn ->
        unboxed(fn ->
          delete_assignment_fixture(assignment, [contender.principal_id])
        end)
      end)

      results =
        subject_lock_race(task_supervisor, test_process, subject, order, %{
          assignment_promotion: fn -> Auth.sign_in_with_discord(%{"sub" => subject}) end,
          permanent_link: fn ->
            Auth.link_discord_identity(contender.principal_id, %{"sub" => subject})
          end
        })

      assert {:ok, %{principal: %{id: principal_id}}} = results.assignment_promotion
      assert principal_id == target.principal_id
      assert {:error, :invalid} = results.permanent_link

      unboxed(fn ->
        assert Repo.get!(StagedAssignment, assignment.id).state == "promoted"

        assert Repo.get_by!(ExternalIdentity,
                 provider: "discord",
                 provider_subject: subject
               ).principal_id == target.principal_id

        refute Repo.exists?(
                 from(i in ExternalIdentity, where: i.principal_id == ^contender.principal_id)
               )
      end)
    end
  end

  defp subject_lock_race(task_supervisor, test_process, subject, order, operations) do
    race_ref = make_ref()

    holder =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            blocker_pid = postgres_backend_pid()
            DiscordSubjectLock.lock!(subject)
            send(test_process, {:subject_lock_held, race_ref, blocker_pid})

            receive do
              {:release_subject_lock, ^race_ref} -> :released
            end
          end)
        end)
      end)

    assert_receive {:subject_lock_held, ^race_ref, blocker_pid}
    baseline_waiter_count = advisory_waiter_count()

    tasks =
      order
      |> Enum.with_index(1)
      |> Enum.map(fn {label, expected_waiter_count} ->
        task =
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            unboxed(fn ->
              send(test_process, {:operation_started, race_ref, label})
              Map.fetch!(operations, label).()
            end)
          end)

        assert_receive {:operation_started, ^race_ref, ^label}

        if expected_waiter_count == 1 do
          assert_direct_advisory_block(blocker_pid)
        end

        assert_advisory_waiter_count(baseline_waiter_count + expected_waiter_count)
        {label, task}
      end)

    send(holder.pid, {:release_subject_lock, race_ref})
    assert {:ok, :released} = Task.await(holder)

    Map.new(tasks, fn {label, task} -> {label, Task.await(task, 10_000)} end)
  end

  defp postgres_backend_pid do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp assert_direct_advisory_block(blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    wait_for_direct_advisory_block(blocker_pid, deadline)
  end

  defp wait_for_direct_advisory_block(blocker_pid, deadline) do
    directly_blocked? =
      unboxed(fn ->
        %{rows: [[directly_blocked?]]} =
          Repo.query!(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1::integer = ANY(pg_blocking_pids(pid)))",
            [blocker_pid],
            log: false
          )

        directly_blocked?
      end)

    cond do
      directly_blocked? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        wait_for_direct_advisory_block(blocker_pid, deadline)

      true ->
        flunk("expected a PostgreSQL backend to block directly on backend #{blocker_pid}")
    end
  end

  defp assert_advisory_waiter_count(expected_count) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    wait_for_advisory_waiters(expected_count, deadline)
  end

  defp wait_for_advisory_waiters(expected_count, deadline) do
    waiter_count = advisory_waiter_count()

    cond do
      waiter_count >= expected_count ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        wait_for_advisory_waiters(expected_count, deadline)

      true ->
        flunk(
          "expected at least #{expected_count} ungranted PostgreSQL advisory locks, got #{waiter_count}"
        )
    end
  end

  defp advisory_waiter_count do
    unboxed(fn ->
      %{rows: [[waiter_count]]} =
        Repo.query!(
          """
          SELECT count(*)
          FROM pg_locks
          WHERE locktype = 'advisory'
            AND NOT granted
            AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
          """,
          [],
          log: false
        )

      waiter_count
    end)
  end

  test "concurrent recovery deliveries converge on one completed Discord-bound acceptance" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    %{acceptance: acceptance, attempt_id: attempt_id, principal_id: principal_id} =
      unboxed(fn ->
        acceptance = acceptance_fixture()

        {:ok, %{state: "discordVerified"}} =
          Onboarding.verify_discord(acceptance.continuation_id, %{
            "sub" => unique_subject("recovery-race"),
            "preferred_username" => "recovery-race-member"
          })

        attempt =
          Repo.get_by!(InvitationAcceptanceAttempt, invitation_id: acceptance.invitation_id)

        attempt
        |> Ecto.Changeset.change(
          status: "provisioned",
          stripe_customer_id: "cus_recovery_race",
          stripe_state: %{
            "setup_intent_id" => "seti_recovery_race",
            "monthly_subscription_id" => "sub_recovery_race"
          },
          acceptance_data: %{
            "continuation_id" => acceptance.continuation_id,
            "next_of_kin_name" => "Grace Hopper",
            "next_of_kin_phone" => "+353810000099",
            "payment" => %{"confirmation_token" => "ctok_recovery_race"}
          }
        )
        |> Repo.update!()

        invitation = Repo.get!(Invitation, acceptance.invitation_id)

        %{
          acceptance: acceptance,
          attempt_id: attempt.id,
          principal_id: invitation.prospective_principal_id
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        delete_member(principal_id)
        delete_acceptances([acceptance.invitation_id])
      end)
    end)

    recoveries =
      for label <- [:first_recovery, :second_recovery] do
        ready_task(task_supervisor, test_process, label, fn ->
          Onboarding.recover_acceptance(attempt_id)
        end)
      end

    for label <- [:first_recovery, :second_recovery] do
      assert_receive {:ready, ^label, pid}
      send(pid, :go)
    end

    assert Enum.all?(recoveries, fn task ->
             match?({:ok, %{state: "accepted"}}, Task.await(task))
           end)

    unboxed(fn ->
      assert Repo.get!(InvitationAcceptanceAttempt, attempt_id).status == "completed"
      assert Repo.get!(Invitation, acceptance.invitation_id).status == "accepted"
      assert Repo.aggregate(from(p in Principal, where: p.id == ^principal_id), :count) == 1
      assert Repo.aggregate(from(m in MemberProfile, where: m.id == ^principal_id), :count) == 1

      assert Repo.aggregate(
               from(p in UserProfile, where: p.principal_id == ^principal_id),
               :count
             ) == 1

      assert Repo.aggregate(from(r in UserRole, where: r.principal_id == ^principal_id), :count) ==
               1

      assert Repo.aggregate(
               from(i in ExternalIdentity, where: i.principal_id == ^principal_id),
               :count
             ) == 1

      refute Repo.exists?(InvitationAcceptanceDiscordSubjectClaim)
      refute Repo.exists?(from(t in PrincipalToken, where: t.principal_id == ^principal_id))
    end)
  end

  test "callback verification and protected restart use one row-lock order without deadlock" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()
    acceptance = unboxed(&acceptance_fixture/0)

    on_exit(fn -> unboxed(fn -> delete_acceptances([acceptance.invitation_id]) end) end)

    invitation = unboxed(fn -> Repo.get!(Invitation, acceptance.invitation_id) end)

    callback_task =
      ready_task(task_supervisor, test_process, :callback, fn ->
        Onboarding.verify_discord(acceptance.continuation_id, %{
          "sub" => unique_subject("callback-restart"),
          "preferred_username" => "callback-restart"
        })
      end)

    restart_task =
      ready_task(task_supervisor, test_process, :restart, fn ->
        Onboarding.start_acceptance(
          invitation.id,
          invitation.email,
          Date.to_iso8601(invitation.date_of_birth),
          acceptance.continuation_id
        )
      end)

    assert_receive {:ready, :callback, callback_pid}
    assert_receive {:ready, :restart, restart_pid}
    send(callback_pid, :go)
    send(restart_pid, :go)

    assert {:ok, %{state: "discordVerified"}} = Task.await(callback_task)

    assert {:ok, %{continuation_id: continuation_id, view: %{state: restart_state}}} =
             Task.await(restart_task)

    assert continuation_id == acceptance.continuation_id
    assert restart_state in ["awaiting_oauth", "discordVerified"]

    unboxed(fn ->
      assert Repo.get!(
               InvitationAcceptanceDiscordContinuation,
               acceptance.continuation_id
             ).status == "verified"

      assert Repo.aggregate(InvitationAcceptanceDiscordSubjectClaim, :count) == 1
    end)
  end

  test "deferred constraints reject a Continuation bound to another Invitation's Attempt" do
    {first, second, second_attempt} =
      unboxed(fn ->
        first = invitation_fixture()
        second = invitation_fixture()

        second_attempt =
          %InvitationAcceptanceAttempt{invitation_id: second.id, acceptance_data: %{}}
          |> Repo.insert!()

        {first, second, second_attempt}
      end)

    on_exit(fn -> unboxed(fn -> delete_acceptances([first.id, second.id]) end) end)

    assert_raise Postgrex.Error, ~r/Discord continuation invitation does not match/, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          %InvitationAcceptanceDiscordContinuation{
            invitation_id: first.id,
            attempt_id: second_attempt.id,
            expires_at:
              DateTime.utc_now() |> DateTime.add(15, :minute) |> DateTime.truncate(:second)
          }
          |> Repo.insert!()

          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end)
    end
  end

  test "deferred constraints reject a Claim whose Continuation is not verified" do
    acceptance = unboxed(&acceptance_fixture/0)
    on_exit(fn -> unboxed(fn -> delete_acceptances([acceptance.invitation_id]) end) end)

    assert_raise Postgrex.Error, ~r/Discord subject claim must belong/, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          %InvitationAcceptanceDiscordSubjectClaim{
            continuation_id: acceptance.continuation_id,
            provider: "discord",
            provider_subject: unique_subject("unverified-owner")
          }
          |> Repo.insert!()

          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end)
    end
  end

  test "deferred constraints reject a verified Continuation without its Claim" do
    acceptance = unboxed(&acceptance_fixture/0)
    on_exit(fn -> unboxed(fn -> delete_acceptances([acceptance.invitation_id]) end) end)

    assert_raise Postgrex.Error, ~r/Verified Discord continuation must own/, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          acceptance.continuation_id
          |> then(&Repo.get!(InvitationAcceptanceDiscordContinuation, &1))
          |> Ecto.Changeset.change(
            status: "verified",
            provider_subject: unique_subject("missing-claim"),
            subject_fingerprint: "test-fingerprint"
          )
          |> Repo.update!()

          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end)
    end
  end

  test "deferred constraints reject a permanent Discord link while a Claim owns the subject" do
    %{acceptance: acceptance, member: member, subject: subject} =
      unboxed(fn ->
        acceptance = acceptance_fixture()
        member = Dhc.MemberFixtures.member_fixture(is_active: true)
        subject = unique_subject("claim-permanent-conflict")

        {:ok, _state} =
          Onboarding.verify_discord(acceptance.continuation_id, %{"sub" => subject})

        %{acceptance: acceptance, member: member, subject: subject}
      end)

    on_exit(fn ->
      unboxed(fn ->
        delete_acceptances([acceptance.invitation_id])
        delete_member(member.principal_id)
      end)
    end)

    assert_raise Postgrex.Error, ~r/Discord subject cannot be both claimed/, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          %ExternalIdentity{
            principal_id: member.principal_id,
            provider: "discord",
            provider_subject: subject,
            metadata: %{}
          }
          |> Repo.insert!()

          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)
      end)
    end
  end

  test "collision audit evidence is immutable" do
    %{acceptance: acceptance, member: member, audit_event: audit_event} =
      unboxed(fn ->
        acceptance = acceptance_fixture()
        member = Dhc.MemberFixtures.member_fixture(is_active: true)
        subject = unique_subject("immutable-audit")

        %ExternalIdentity{
          principal_id: member.principal_id,
          provider: "discord",
          provider_subject: subject,
          metadata: %{}
        }
        |> Repo.insert!()

        {:error, :collision} =
          Onboarding.verify_discord(acceptance.continuation_id, %{"sub" => subject})

        %{
          acceptance: acceptance,
          member: member,
          audit_event: Repo.one!(InvitationAcceptanceDiscordCollisionAuditEvent)
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        delete_acceptances([acceptance.invitation_id])
        delete_member(member.principal_id)
      end)
    end)

    assert_raise Postgrex.Error, ~r/Discord collision audit events are immutable/, fn ->
      unboxed(fn ->
        from(event in InvitationAcceptanceDiscordCollisionAuditEvent,
          where: event.id == ^audit_event.id
        )
        |> Repo.update_all(set: [reason_code: "active_claim"])
      end)
    end
  end

  defp ready_task(task_supervisor, test_process, label, fun) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      send(test_process, {:ready, label, self()})

      receive do
        :go -> unboxed(fun)
      end
    end)
  end

  defp assert_single_stripe_progression(owner_label) do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()
    acceptance = unboxed(&verified_acceptance_fixture/0)

    on_exit(fn ->
      unboxed(fn ->
        delete_acceptances([acceptance.invitation_id])
        delete_member(acceptance.principal_id)
      end)
    end)

    tasks =
      Map.new([:first, :second], fn label ->
        task =
          ready_task(task_supervisor, test_process, label, fn ->
            Process.put(:acceptance_label, label)

            result =
              Onboarding.accept(
                acceptance.invitation_id,
                acceptance.continuation_id,
                "Next of Kin",
                "+353810000001",
                %{confirmation_token: "ctok_concurrency"}
              )

            send(test_process, {:acceptance_finished, label, result})
            result
          end)

        assert_receive {:ready, ^label, pid}
        {label, %{task: task, pid: pid}}
      end)

    duplicate_label = if owner_label == :first, do: :second, else: :first
    send(tasks[owner_label].pid, :go)

    assert_receive {:stripe_progression_started, ^owner_label, owner_pid}

    send(tasks[duplicate_label].pid, :go)

    duplicate_outcome =
      receive do
        {:acceptance_finished, ^duplicate_label, result} -> {:returned, result}
      after
        250 -> :blocked
      end

    additional_progression =
      receive do
        {:stripe_progression_started, ^duplicate_label, duplicate_pid} -> duplicate_pid
      after
        100 -> nil
      end

    send(owner_pid, :release_stripe_progression)
    if additional_progression, do: send(additional_progression, :release_stripe_progression)

    owner_result = Task.await(tasks[owner_label].task)
    duplicate_result = Task.await(tasks[duplicate_label].task)

    assert duplicate_outcome == {:returned, {:error, :acceptance_in_progress}}
    assert additional_progression == nil
    assert {:ok, %{member_id: member_id}} = owner_result
    assert member_id == acceptance.principal_id
    assert duplicate_result == {:error, :acceptance_in_progress}
    refute_received {:cancel_membership, _stripe_state}

    unboxed(fn ->
      assert %InvitationAcceptanceAttempt{status: "completed"} =
               Repo.get_by!(InvitationAcceptanceAttempt,
                 invitation_id: acceptance.invitation_id
               )
    end)
  end

  defp verified_acceptance_fixture do
    acceptance = acceptance_fixture()
    subject = unique_subject("stripe-progression")

    assert {:ok, %{state: "discordVerified"}} =
             Onboarding.verify_discord(acceptance.continuation_id, %{
               "sub" => subject,
               "preferred_username" => "stripe-progression"
             })

    invitation = Repo.get!(Invitation, acceptance.invitation_id)

    Map.put(acceptance, :principal_id, invitation.prospective_principal_id)
  end

  defp acceptance_fixture do
    invitation = invitation_fixture()

    {:ok, state} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    %{invitation_id: invitation.id, continuation_id: state.continuation_id}
  end

  defp invitation_fixture do
    %Invitation{
      email: "ale-213-#{System.unique_integer([:positive])}@example.com",
      prospective_principal_id: Ecto.UUID.generate(),
      status: "pending",
      expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
      invitation_type: "member",
      first_name: "Ada",
      last_name: "Lovelace",
      phone_number: "+353810000000",
      date_of_birth: ~D[1990-01-01]
    }
    |> Repo.insert!()
  end

  defp unique_subject(label),
    do: "ale-213-#{label}-#{System.unique_integer([:positive])}"

  defp restore_env(key, nil), do: Application.delete_env(:dhc, key)
  defp restore_env(key, value), do: Application.put_env(:dhc, key, value)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp delete_acceptances(invitation_ids) do
    Repo.transaction(fn ->
      continuation_ids =
        Repo.all(
          from(c in InvitationAcceptanceDiscordContinuation,
            where: c.invitation_id in ^invitation_ids,
            select: c.id
          )
        )

      attempt_ids =
        Repo.all(
          from(a in InvitationAcceptanceAttempt,
            where: a.invitation_id in ^invitation_ids,
            select: a.id
          )
        )

      # Immutable audit rows are intentionally undeletable through ordinary
      # DELETE. Test cleanup truncates only after ExUnit has serialized this
      # real-Postgres module, then removes the rest in one deferred transaction.
      Repo.query!("TRUNCATE invitation_acceptance_discord_collision_audit_events")

      Repo.delete_all(
        from(c in InvitationAcceptanceDiscordSubjectClaim,
          where: c.continuation_id in ^continuation_ids
        )
      )

      Repo.delete_all(
        from(c in InvitationAcceptanceDiscordContinuation, where: c.id in ^continuation_ids)
      )

      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("?->>'attempt_id'", j.args) in ^attempt_ids
        )
      )

      Repo.delete_all(from(a in InvitationAcceptanceAttempt, where: a.id in ^attempt_ids))
      Repo.delete_all(from(i in Invitation, where: i.id in ^invitation_ids))
    end)
  end

  defp delete_member(principal_id) do
    Repo.delete_all(from(t in PrincipalToken, where: t.principal_id == ^principal_id))
    Repo.delete_all(from(i in ExternalIdentity, where: i.principal_id == ^principal_id))

    profile_ids =
      Repo.all(from(p in UserProfile, where: p.principal_id == ^principal_id, select: p.id))

    Repo.delete_all(from(m in MemberProfile, where: m.user_profile_id in ^profile_ids))
    Repo.delete_all(from(p in UserProfile, where: p.principal_id == ^principal_id))
    Repo.delete_all(from(p in Principal, where: p.id == ^principal_id))
  end

  defp delete_assignment_fixture(assignment, extra_principal_ids \\ []) do
    assignment = Repo.get!(StagedAssignment, assignment.id)
    capture = Repo.get!(RosterReceipt, assignment.capture_id)

    Repo.delete_all(from(t in PrincipalToken, where: t.principal_id == ^assignment.principal_id))

    Repo.delete_all(
      from(i in ExternalIdentity, where: i.principal_id == ^assignment.principal_id)
    )

    # ALE-217 audit rows are immutable in production. These unboxed tests must
    # remove their own durable fixtures so later global-count tests remain
    # isolated, therefore teardown briefly disables only the audit-delete guard.
    Repo.query!(
      "ALTER TABLE staged_discord_assignment_audit_events DISABLE TRIGGER ale217_reject_audit_mutation"
    )

    try do
      Repo.delete_all(
        from(e in StagedAssignmentAuditEvent, where: e.assignment_id == ^assignment.id)
      )
    after
      Repo.query!(
        "ALTER TABLE staged_discord_assignment_audit_events ENABLE TRIGGER ale217_reject_audit_mutation"
      )
    end

    Repo.delete_all(from(r in AssignmentStageResult, where: r.assignment_id == ^assignment.id))
    Repo.delete_all(from(a in StagedAssignment, where: a.id == ^assignment.id))

    if assignment.review_execution_id do
      Repo.delete_all(
        from(e in AssignmentReviewExecution, where: e.id == ^assignment.review_execution_id)
      )
    end

    Repo.delete_all(
      from(e in AssignmentStageExecution, where: e.id == ^assignment.stage_execution_id)
    )

    Repo.delete_all(from(r in RosterReceipt, where: r.id == ^capture.id))

    if capture.preflight_receipt_id do
      Repo.delete_all(from(r in RosterReceipt, where: r.id == ^capture.preflight_receipt_id))
    end

    [
      assignment.principal_id,
      assignment.prepared_by_principal_id,
      assignment.approved_by_principal_id
      | extra_principal_ids
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&delete_member/1)
  end
end
