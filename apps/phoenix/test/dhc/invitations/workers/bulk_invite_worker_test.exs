defmodule Dhc.Invitations.BulkInviteWorkerTest do
  use ExUnit.Case, async: false

  alias Dhc.Invitations.BulkInviteWorker

  describe "perform/1 validation" do
    test "returns validation errors when invites are missing" do
      assert {:error, {:validation, errors}} =
               BulkInviteWorker.perform(%Oban.Job{
                 args: %{"user" => %{"id" => Ecto.UUID.generate()}}
               })

      assert "missing invites" in errors
    end

    test "returns validation errors when invites are empty" do
      args = %{"invites" => [], "user" => %{"id" => Ecto.UUID.generate()}}

      assert {:error, {:validation, errors}} = BulkInviteWorker.perform(%Oban.Job{args: args})
      assert "invites must be a non-empty list" in errors
    end

    test "returns validation errors when user id is missing" do
      args = %{"invites" => [%{"email" => "member@example.com"}], "user" => %{}}

      assert {:error, {:validation, errors}} = BulkInviteWorker.perform(%Oban.Job{args: args})
      assert "user.id is required" in errors
    end
  end
end
