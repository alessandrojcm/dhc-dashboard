defmodule Dhc.Inventory.TargetFlags do
  @moduledoc """
  ALE-282 kill flags for the additive inventory expand.

  Two independently controlled server-side flags gate the future target
  surfaces. Both default to `false` (nothing target is exposed), so deploying
  the expand migration changes no behavior. Either surface can be stopped
  without restoring legacy writes — disabling a flag only hides target reads
  or rejects target commands; legacy paths are never re-enabled by these
  flags.

    * `:catalog_reads_enabled` — target member/operator catalog reads.
    * `:commands_enabled` — every target mutating command.

  Backed by application env so releases can flip them without a deploy:

      config :dhc, Dhc.Inventory.TargetFlags,
        catalog_reads_enabled: false,
        commands_enabled: false

  Tests toggle them with `Application.put_env/3`; always reset in `on_exit/1`.
  """

  @type surface :: :catalog_reads | :commands

  @doc """
  Returns whether the given target surface is enabled.
  """
  @spec enabled?(surface()) :: boolean()
  def enabled?(:catalog_reads), do: get(:catalog_reads_enabled)
  def enabled?(:commands), do: get(:commands_enabled)

  @doc """
  Returns whether target catalog reads are enabled.
  """
  @spec catalog_reads_enabled?() :: boolean()
  def catalog_reads_enabled?, do: enabled?(:catalog_reads)

  @doc """
  Returns whether target commands are enabled.
  """
  @spec commands_enabled?() :: boolean()
  def commands_enabled?, do: enabled?(:commands)

  @doc """
  Returns `:ok` when target catalog reads are enabled, `{:error, :disabled}`
  otherwise. Future target read entry points call this first.
  """
  @spec ensure_catalog_reads() :: :ok | {:error, :disabled}
  def ensure_catalog_reads do
    if catalog_reads_enabled?(), do: :ok, else: {:error, :disabled}
  end

  @doc """
  Returns `:ok` when target commands are enabled, `{:error, :disabled}`
  otherwise. Future target command entry points call this first.
  """
  @spec ensure_commands() :: :ok | {:error, :disabled}
  def ensure_commands do
    if commands_enabled?(), do: :ok, else: {:error, :disabled}
  end

  defp get(key) do
    Application.get_env(:dhc, __MODULE__, [])
    |> Keyword.get(key, false)
    |> then(fn value -> value == true end)
  end
end
