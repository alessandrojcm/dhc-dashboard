defmodule Dhc.Invitations.AtomicReissueTest do
  use Dhc.DataCase, async: false

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Repository
  alias Ecto.Adapters.SQL.Sandbox

  # Duplicate invitations are rejected while a `pending` invitation exists
  # for the email. Re-inviting is allowed again once nothing is pending.
  # The partial unique index `invitations_email_pending_unique` remains the
  # concurrency backstop for racing inserts.
  describe "create_invitation_record/3" do
    test "rejects the invite while a pending invitation exists for the email" do
      created_by_id = insert_principal!("admin@example.com")
      invite_data = invite_data("member@example.com")

      assert {:ok, invitation_id} =
               Repository.create_invitation_record(invite_data, invite_data, created_by_id)

      assert {:error, {:create_invitation, :duplicate_pending_invitation}} =
               Repository.create_invitation_record(invite_data, invite_data, created_by_id)

      # Exactly one row for the email, untouched, still pending.
      assert [%Invitation{id: ^invitation_id, status: "pending"}] =
               Repo.all(from(i in Invitation, where: i.email == "member@example.com"))
    end

    test "rejects duplicates case-insensitively" do
      created_by_id = insert_principal!("case-admin@example.com")

      assert {:ok, _original_id} =
               Repository.create_invitation_record(
                 invite_data("Member@Example.com"),
                 invite_data("Member@Example.com"),
                 created_by_id
               )

      assert {:error, {:create_invitation, :duplicate_pending_invitation}} =
               Repository.create_invitation_record(
                 invite_data("member@example.com"),
                 invite_data("member@example.com"),
                 created_by_id
               )

      assert 1 ==
               Repo.aggregate(
                 from(i in Invitation, where: i.email == "MEMBER@example.com"),
                 :count
               )
    end

    test "allows re-inviting once no pending invitation remains" do
      created_by_id = insert_principal!("reinvite-admin@example.com")
      invite_data = invite_data("lapsed@example.com")

      assert {:ok, original_id} =
               Repository.create_invitation_record(invite_data, invite_data, created_by_id)

      Repo.update_all(
        from(i in Invitation, where: i.id == ^original_id),
        set: [status: "expired"]
      )

      assert {:ok, replacement_id} =
               Repository.create_invitation_record(invite_data, invite_data, created_by_id)

      refute replacement_id == original_id

      assert %Invitation{status: "pending"} = Repo.get!(Invitation, replacement_id)
      assert %Invitation{status: "expired"} = Repo.get!(Invitation, original_id)
    end

    test "concurrent duplicate invites fail loud instead of creating two pending invitations" do
      email = "atomic-reissue-#{System.unique_integer([:positive])}@example.com"
      invite_data = invite_data(email)

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
