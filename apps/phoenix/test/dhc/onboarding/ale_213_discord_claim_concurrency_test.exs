defmodule Dhc.Onboarding.Ale213DiscordClaimConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{ExternalIdentity, Principal, PrincipalToken}
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
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

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

  test "a Claim cannot win against promotion of its approved assignment" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    %{acceptance: acceptance, target: target, assignment: assignment, subject: subject} =
      unboxed(fn ->
        acceptance = acceptance_fixture()
        target = Dhc.MemberFixtures.member_fixture(is_active: true)
        subject = unique_subject("claim-promotion")

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

    promotion =
      ready_task(task_supervisor, test_process, :promotion, fn ->
        Auth.sign_in_with_discord(%{"sub" => subject})
      end)

    claim =
      ready_task(task_supervisor, test_process, :claim, fn ->
        Onboarding.verify_discord(acceptance.continuation_id, %{"sub" => subject})
      end)

    assert_receive {:ready, :promotion, promotion_pid}
    assert_receive {:ready, :claim, claim_pid}
    send(promotion_pid, :go)
    send(claim_pid, :go)

    assert {:ok, %{principal: %{id: principal_id}}} = Task.await(promotion)
    assert principal_id == target.principal_id
    assert {:error, :collision} = Task.await(claim)

    unboxed(fn ->
      assert Repo.get!(StagedAssignment, assignment.id).state == "promoted"
      assert Repo.get_by!(ExternalIdentity, provider: "discord", provider_subject: subject)
      refute Repo.get_by(InvitationAcceptanceDiscordSubjectClaim, provider_subject: subject)
    end)
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

    callbacks =
      for label <- [:first_promotion, :second_promotion] do
        ready_task(task_supervisor, test_process, label, fn ->
          Auth.sign_in_with_discord(%{"sub" => subject})
        end)
      end

    for label <- [:first_promotion, :second_promotion] do
      assert_receive {:ready, ^label, pid}
      send(pid, :go)
    end

    assert Enum.all?(callbacks, fn task ->
             match?(
               {:ok, %{principal: %{id: id}}} when id == target.principal_id,
               Task.await(task)
             )
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

  test "promotion wins a concurrent permanent-link collision without partial state" do
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    %{target: target, contender: contender, assignment: assignment, subject: subject} =
      unboxed(fn ->
        target = Dhc.MemberFixtures.member_fixture(is_active: true)
        contender = Dhc.MemberFixtures.member_fixture(is_active: true)
        subject = unique_subject("permanent-collision")

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

    promotion =
      ready_task(task_supervisor, test_process, :assignment_promotion, fn ->
        Auth.sign_in_with_discord(%{"sub" => subject})
      end)

    link =
      ready_task(task_supervisor, test_process, :permanent_link, fn ->
        Auth.link_discord_identity(contender.principal_id, %{"sub" => subject})
      end)

    assert_receive {:ready, :assignment_promotion, promotion_pid}
    assert_receive {:ready, :permanent_link, link_pid}
    send(promotion_pid, :go)
    send(link_pid, :go)

    assert {:ok, %{principal: %{id: principal_id}}} = Task.await(promotion)
    assert principal_id == target.principal_id
    assert {:error, :invalid} = Task.await(link)

    unboxed(fn ->
      assert Repo.get!(StagedAssignment, assignment.id).state == "promoted"

      assert Repo.get_by!(ExternalIdentity, provider: "discord", provider_subject: subject).principal_id ==
               target.principal_id

      refute Repo.exists?(
               from(i in ExternalIdentity, where: i.principal_id == ^contender.principal_id)
             )
    end)
  end

  defp ready_task(task_supervisor, test_process, label, fun) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      send(test_process, {:ready, label, self()})

      receive do
        :go -> unboxed(fun)
      end
    end)
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

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp delete_acceptances(invitation_ids) do
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

    Repo.delete_all(
      from(c in InvitationAcceptanceDiscordSubjectClaim,
        where: c.continuation_id in ^continuation_ids
      )
    )

    Repo.delete_all(
      from(c in InvitationAcceptanceDiscordContinuation, where: c.id in ^continuation_ids)
    )

    Repo.delete_all(from(a in InvitationAcceptanceAttempt, where: a.id in ^attempt_ids))
    Repo.delete_all(from(i in Invitation, where: i.id in ^invitation_ids))
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
