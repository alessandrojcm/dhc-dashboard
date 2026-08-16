defmodule Dhc.Invitations.AtomicReissueTest do
  use Dhc.DataCase, async: false

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Repository
  alias Ecto.Adapters.SQL.Sandbox

  describe "create_invitation_record/3" do
    test "keeps the existing pending invitation when its replacement cannot be inserted" do
      created_by_id = insert_principal!("admin@example.com")
      invite_data = invite_data("member@example.com")

      assert {:ok, invitation_id} =
               Repository.create_invitation_record(invite_data, invite_data, created_by_id)

      Repo.query!("""
      ALTER TABLE invitations
      ADD CONSTRAINT reject_pending_member_invitation
      CHECK (email <> 'member@example.com' OR status <> 'pending') NOT VALID
      """)

      on_exit(fn ->
        Repo.query!(
          "ALTER TABLE invitations DROP CONSTRAINT IF EXISTS reject_pending_member_invitation"
        )
      end)

      assert {:error, {:create_invitation, _reason}} =
               Repository.create_invitation_record(invite_data, invite_data, created_by_id)

      assert %Invitation{status: "pending"} = Repo.get!(Invitation, invitation_id)
    end

    test "reissues against the canonical email regardless of case" do
      created_by_id = insert_principal!("case-admin@example.com")

      assert {:ok, original_id} =
               Repository.create_invitation_record(
                 invite_data("Member@Example.com"),
                 invite_data("Member@Example.com"),
                 created_by_id
               )

      assert {:ok, replacement_id} =
               Repository.create_invitation_record(
                 invite_data("member@example.com"),
                 invite_data("member@example.com"),
                 created_by_id
               )

      assert %Invitation{status: "expired"} = Repo.get!(Invitation, original_id)
      assert %Invitation{status: "pending"} = Repo.get!(Invitation, replacement_id)

      assert 1 ==
               Repo.aggregate(
                 from(i in Invitation,
                   where: i.email == "MEMBER@example.com" and i.status == "pending"
                 ),
                 :count
               )
    end

    test "concurrent reissues fail loud instead of silently discarding a Principal id" do
      email = "atomic-reissue-#{System.unique_integer([:positive])}@example.com"
      invite_data = invite_data(email)

      assert {:ok, original_id} =
               outside_sandbox(fn ->
                 Repository.create_invitation_record(invite_data, invite_data, nil)
               end)

      outside_sandbox(fn ->
        Repo.query!("""
        CREATE OR REPLACE FUNCTION delay_pending_invitation_for_concurrency_test() RETURNS trigger AS $$
        BEGIN
          IF NEW.email::text LIKE 'atomic-reissue-%' THEN
            PERFORM pg_sleep(0.1);
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        Repo.query!("""
        CREATE TRIGGER delay_pending_invitation_for_concurrency_test
        BEFORE INSERT ON invitations
        FOR EACH ROW EXECUTE FUNCTION delay_pending_invitation_for_concurrency_test()
        """)
      end)

      on_exit(fn ->
        outside_sandbox(fn ->
          Repo.delete_all(from i in Invitation, where: i.email == ^email)

          Repo.query!(
            "DROP TRIGGER IF EXISTS delay_pending_invitation_for_concurrency_test ON invitations"
          )

          Repo.query!("DROP FUNCTION IF EXISTS delay_pending_invitation_for_concurrency_test()")
        end)
      end)

      results =
        [invite_data, invite_data]
        |> Task.async_stream(
          fn data ->
            outside_sandbox(fn -> Repository.create_invitation_record(data, data, nil) end)
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert 1 == Enum.count(results, &match?({:ok, _invitation_id}, &1))
      assert 1 == Enum.count(results, &match?({:error, {:create_invitation, _reason}}, &1))

      assert 1 ==
               outside_sandbox(fn ->
                 Repo.aggregate(
                   from(i in Invitation, where: i.email == ^email and i.status == "pending"),
                   :count
                 )
               end)

      assert %Invitation{status: "expired"} =
               outside_sandbox(fn -> Repo.get!(Invitation, original_id) end)
    end
  end

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp insert_principal!(email) do
    id = Ecto.UUID.generate()
    {:ok, _principal} = Dhc.Auth.register_principal_with_id(id, %{email: email})
    id
  end

  defp invite_data(email) do
    %{
      "firstName" => "Ada",
      "lastName" => "Lovelace",
      "email" => email,
      "phoneNumber" => "+353810000001",
      "dateOfBirth" => "1990-01-01"
    }
  end
end
