defmodule Dhc.WorkshopAnnouncements.WorkerTest do
  use ExUnit.Case, async: true

  alias Dhc.WorkshopAnnouncements.Worker

  describe "perform/1 with invalid args" do
    test "returns error when workshop_id is missing" do
      args = %{"announcement_type" => "created"}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing workshop_id" in errors
    end

    test "returns error when workshop_id is empty string" do
      args = %{"workshop_id" => "", "announcement_type" => "created"}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing workshop_id" in errors
    end

    test "returns error when workshop_id is not a valid UUID" do
      args = %{"workshop_id" => "not-a-uuid", "announcement_type" => "created"}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "invalid workshop_id format" in errors
    end

    test "returns error when announcement_type is missing" do
      args = %{"workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479"}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing announcement_type" in errors
    end

    test "returns error when announcement_type is invalid" do
      args = %{
        "workshop_id" => "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "announcement_type" => "invalid_type"
      }

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "invalid announcement_type" in errors
    end

    test "accumulates multiple validation errors" do
      args = %{}

      assert {:error, {:validation, errors}} = Worker.perform(%Oban.Job{args: args})
      assert "missing workshop_id" in errors
      assert "missing announcement_type" in errors
      assert "invalid announcement_type" in errors
    end
  end
end
