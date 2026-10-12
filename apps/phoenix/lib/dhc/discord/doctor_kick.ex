defmodule Dhc.Discord.DoctorKick do
  @moduledoc """
  The Discord Doctor's kick decision and audit-log wording (ALE-419).

  One pure ladder, `decide/2`, answers whether a classified server account can
  be kicked: `:bulk` (with other accounts), `:single` (only as the one target
  of a request — a pending link), or `:none` with a staff-facing refusal.
  `Dhc.Discord` calls it both to tell the report what each row allows and to
  enforce it when a kick request arrives, so the page's offer and the
  server's refusal cannot disagree.

  The audit reason is the kick's only record (Discord's audit log, read by
  people), so it names the bucket by the label the page shows, never its
  identifier: `DHC Doctor — <admin>: Linked – inactive — <note>`.
  """

  @type bucket :: :linked_active | :linked_inactive | :pending_link | :unrecognized
  @type kick :: :bulk | :single | :none
  @type decision :: {:bulk | :single, nil} | {:none, String.t()}

  @typedoc "The facts of a classified server account the ladder reads."
  @type row :: %{
          required(:bucket) => bucket(),
          required(:bot) => boolean(),
          required(:protected) => boolean(),
          required(:membership_status) => :active | :paused | :inactive | nil,
          optional(atom()) => term()
        }

  @pending_only_alone "Pending links can only be kicked one at a time"
  @kickable_buckets [:linked_inactive, :pending_link, :unrecognized]

  @labels %{
    linked_active: "Linked – active",
    linked_inactive: "Linked – inactive",
    pending_link: "Pending link",
    unrecognized: "Unrecognized"
  }

  @doc """
  Decides what may be done to one account.

  Pass `multiple_targets?: true` when the account is one of several targets
  of a kick request: a pending link is then refused.
  """
  @spec decide(row(), keyword()) :: decision()
  def decide(row, options \\ []) do
    multiple_targets? = Keyword.get(options, :multiple_targets?, false)

    cond do
      row.bot -> {:none, "Bot account"}
      row.protected -> {:none, "Protected member"}
      row.membership_status == :paused -> {:none, "Paused member"}
      row.bucket == :linked_active -> {:none, "Active member"}
      row.bucket == :pending_link and multiple_targets? -> {:none, @pending_only_alone}
      row.bucket == :pending_link -> {:single, nil}
      row.bucket in @kickable_buckets -> {:bulk, nil}
    end
  end

  @doc "The page's label for a bucket, used in the audit reason."
  @spec bucket_label(bucket()) :: String.t()
  def bucket_label(bucket), do: Map.fetch!(@labels, bucket)

  @doc """
  The audit-reason prefix for each kickable bucket, for the admin making the
  request. Built per request: it names that admin.
  """
  @spec reason_prefixes(String.t()) :: %{bucket() => String.t()}
  def reason_prefixes(admin_name) do
    Map.new(@kickable_buckets, &{&1, prefix(admin_name, &1)})
  end

  @doc "The audit reason written to Discord: the prefix, then ` — <note>` when one is given."
  @spec audit_reason(String.t(), bucket(), String.t() | nil) :: String.t()
  def audit_reason(admin_name, bucket, note) do
    base = prefix(admin_name, bucket)

    case note && String.trim(note) do
      blank when blank in [nil, ""] -> base
      trimmed -> "#{base} — #{trimmed}"
    end
  end

  defp prefix(admin_name, bucket), do: "DHC Doctor — #{admin_name}: #{bucket_label(bucket)}"
end
