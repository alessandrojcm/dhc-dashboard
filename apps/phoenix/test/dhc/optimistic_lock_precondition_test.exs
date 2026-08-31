defmodule Dhc.OptimisticLockPreconditionTest do
  use ExUnit.Case, async: true

  alias Dhc.OptimisticLock

  describe "check_version/2" do
    test "allows a missing expected version" do
      entity = %{lock_version: 3}

      assert :ok = OptimisticLock.check_version(entity, nil)
    end

    test "allows a wildcard for an existing entity" do
      entity = %{lock_version: 3}

      assert :ok = OptimisticLock.check_version(entity, :*)
    end

    test "allows an equal version" do
      entity = %{lock_version: 3}

      assert :ok = OptimisticLock.check_version(entity, 3)
    end

    test "returns the current entity when versions differ" do
      entity = %{lock_version: 3, id: "current"}

      assert {:error, {:version_precondition_failed, ^entity}} =
               OptimisticLock.check_version(entity, 2)
    end
  end
end
