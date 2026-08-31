defmodule Dhc.OptimisticLock do
  @moduledoc """
  Domain-level optimistic-concurrency precondition checks.

  The caller owns entity loading and domain policy. This module only compares
  a supplied expected version with an existing entity's `lock_version`.
  """

  @type expected_version :: nil | :* | pos_integer()

  @doc """
  Check an expected version against an existing entity.

  Missing expectations preserve unconditional behavior, and `:*` succeeds
  because the supplied entity already exists. A mismatch returns the current
  entity so the caller can expose or otherwise handle the conflict.
  """
  @spec check_version(%{required(:lock_version) => pos_integer()}, expected_version()) ::
          :ok | {:error, {:version_precondition_failed, map()}}
  def check_version(_entity, nil), do: :ok
  def check_version(_entity, :*), do: :ok

  def check_version(%{lock_version: version}, version) when is_integer(version), do: :ok

  def check_version(entity, expected_version) when is_integer(expected_version) do
    {:error, {:version_precondition_failed, entity}}
  end
end
