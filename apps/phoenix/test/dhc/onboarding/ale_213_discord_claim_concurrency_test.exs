defmodule Dhc.Onboarding.Ale213DiscordClaimConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{ExternalIdentity, Principal, PrincipalToken}
  alias Dhc.Invitations.Invitation
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
end
