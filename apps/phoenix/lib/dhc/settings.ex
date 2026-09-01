defmodule Dhc.Settings do
  @moduledoc """
  Generic admin-managed settings context.

  Owns only cross-domain/system configuration allowlisted for the generic
  Settings API. A value being stored in the `settings` table does not
  automatically make it part of the generic Settings API; domain-owned values
  (e.g. `waitlist_open`, `stripe_membership_price_ids`) are intentionally not
  exposed here and remain owned by their domain contexts.

  ## Allowlist (Settings v1)

    * `hema_insurance_form_link` — non-empty http/https URL string
    * `subscription_max_pause_months` — integer, valid range 1..24
    * `subscription_min_pause_days` — integer, valid range 1..365

  ## RBAC

  Generic Settings reads and writes require one of:
  `president`, `committee_coordinator`, `admin`. Enforced at the router layer
  via `DhcWeb.Plugs.RequireAuth` (see the `settings_admin_api` pipeline).
  """

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.Settings.Setting

  @allowlisted_keys ~w(hema_insurance_form_link subscription_max_pause_months subscription_min_pause_days)

  @type key :: String.t()
  @type value :: String.t() | integer()
  @type item :: %{
          key: String.t(),
          value: value | nil,
          description: String.t() | nil,
          lock_version: pos_integer() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Returns the list of allowlisted setting keys.
  """
  @spec allowlisted_keys() :: [String.t()]
  def allowlisted_keys, do: @allowlisted_keys

  @doc """
  Returns whether the given key is allowlisted for the generic Settings API.
  """
  @spec allowlisted?(String.t()) :: boolean()
  def allowlisted?(key), do: key in @allowlisted_keys

  @doc """
  Lists all allowlisted generic settings.

  Missing allowlisted rows are returned with `value: nil` so the API can
  surface "not configured" without raising. Rows are ordered by the allowlist
  for stable output.
  """
  @spec list() :: [item()]
  def list do
    rows =
      from(s in Setting, where: s.key in ^@allowlisted_keys, select: s)
      |> Repo.all()
      |> Map.new(&{&1.key, &1})

    Enum.map(@allowlisted_keys, fn key ->
      row_to_item(Map.get(rows, key), key)
    end)
  end

  @doc """
  Returns one allowlisted setting as a domain item, or `{:error, :not_found}`
  when the key is not allowlisted (ADR 0023 Phase 1.3: single-entity reads
  need the version witness for If-None-Match).

  A missing configured row is surfaced as `{:error, :missing}` (server/data
  error) rather than a value-nil item, since conditional requests have no
  version to validate against.
  """
  @spec get(String.t()) :: {:ok, item()} | {:error, :not_found} | {:error, :missing}
  def get(key) do
    cond do
      not allowlisted?(key) ->
        {:error, :not_found}

      not row_exists?(key) ->
        {:error, :missing}

      true ->
        {:ok, fetch_item!(key)}
    end
  end

  @doc """
  Updates one allowlisted setting by key, optionally guarded by an expected
  `lock_version` (ADR 0023, If-Match precondition).

  ## Value coercion

  Integer-typed keys accept either an integer or a string holding an integer;
  the string is coerced to an integer for validation and persisted back as a
  string (the `settings.value` column is `text`).

  ## Returns

    * `{:ok, item}` — the updated setting as a domain item
    * `{:error, :not_found}` — the key is not allowlisted (404)
    * `{:error, :missing}` — the configured row does not exist (server/data error)
    * `{:error, :version_precondition_failed, item}` — If-Match version
      mismatch; carries the current item for the 412 body
    * `{:error, :invalid_value, detail}` — validation failed (422)
    * `{:error, :no_value}` — the request carried no value (422)
  """
  @spec update(String.t(), term(), keyword()) ::
          {:ok, item()}
          | {:error, :not_found}
          | {:error, :missing}
          | {:error, {:version_precondition_failed, item()}}
          | {:error, :no_value}
          | {:error, :invalid_value, String.t()}
  def update(key, value, opts \\ []) when is_list(opts) do
    cond do
      not allowlisted?(key) ->
        {:error, :not_found}

      is_nil(value) ->
        {:error, :no_value}

      true ->
        with {:ok, row} <- fetch_row(key),
             :ok <- check_precondition(row, opts),
             {:ok, coerced} <- coerce_value(key, value),
             {:ok, validated} <- validate_value(key, coerced),
             {:ok, _updated} <- persist(row, to_string(validated)) do
          {:ok, fetch_item!(key)}
        else
          {:version_precondition_failed, current} ->
            {:error, {:version_precondition_failed, current}}

          {:error, :stale} ->
            current_setting_error(key)

          {:error, :missing} ->
            {:error, :missing}

          {:error, :invalid_value, detail} ->
            {:error, :invalid_value, detail}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, :invalid_value, changeset_error_detail(changeset)}
        end
    end
  end

  # If-Match precondition check — ADR 0023 (ALE-267). Absent or `*` passes;
  # a version mismatch fails fast without applying any changes.
  defp check_precondition(row, opts) do
    case Keyword.fetch(opts, :expected_lock_version) do
      :error ->
        :ok

      {:ok, :*} ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        check_version(row, expected)

      {:ok, expected_versions} when is_list(expected_versions) ->
        check_version(row, expected_versions)
    end
  end

  defp check_version(row, expected) do
    if row.lock_version in List.wrap(expected) do
      :ok
    else
      {:version_precondition_failed, row_to_item(row, row.key)}
    end
  end

  # ── Reads ──────────────────────────────────────────────────────────────

  defp row_exists?(key) do
    from(s in Setting, where: s.key == ^key, select: count(s.id))
    |> Repo.one()
    |> Kernel.>(0)
  end

  defp fetch_row(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> {:error, :missing}
      row -> {:ok, row}
    end
  end

  defp fetch_item!(key) do
    row = Repo.one!(from(s in Setting, where: s.key == ^key, select: s))
    row_to_item(row, key)
  end

  defp current_setting_error(key) do
    case fetch_row(key) do
      {:ok, current} -> {:error, {:version_precondition_failed, row_to_item(current, key)}}
      {:error, :missing} -> {:error, :missing}
    end
  end

  defp row_to_item(nil, key) do
    %{key: key, value: nil, description: nil, lock_version: nil, updated_at: nil}
  end

  defp row_to_item(%Setting{} = row, _key) do
    %{
      key: row.key,
      value: decode_value(row.key, row.value),
      description: row.description,
      lock_version: row.lock_version,
      updated_at: row.updated_at
    }
  end

  # ── Value coercion & validation ───────────────────────────────────────

  # Integer-typed keys coerce string inputs to integers.
  defp coerce_value("subscription_max_pause_months", value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_value, "must be an integer"}
    end
  end

  defp coerce_value("subscription_min_pause_days", value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_value, "must be an integer"}
    end
  end

  defp coerce_value(_key, value), do: {:ok, value}

  defp validate_value("hema_insurance_form_link", value) when not is_binary(value) do
    {:error, :invalid_value, "must be a string"}
  end

  defp validate_value("hema_insurance_form_link", value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :invalid_value, "must be a non-empty URL"}

      not (String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://")) ->
        {:error, :invalid_value, "must be an http or https URL"}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_value("subscription_max_pause_months", n) when is_integer(n) do
    cond do
      n < 1 -> {:error, :invalid_value, "must be at least 1"}
      n > 24 -> {:error, :invalid_value, "must be at most 24"}
      true -> {:ok, n}
    end
  end

  defp validate_value("subscription_min_pause_days", n) when is_integer(n) do
    cond do
      n < 1 -> {:error, :invalid_value, "must be at least 1"}
      n > 365 -> {:error, :invalid_value, "must be at most 365"}
      true -> {:ok, n}
    end
  end

  defp validate_value(key, _value) when key in @allowlisted_keys do
    {:error, :invalid_value, "invalid value type"}
  end

  # ── Persistence ───────────────────────────────────────────────────────

  # Persisted via a struct changeset so the optimistic lock (ADR 0023) bumps
  # `lock_version` on every write. A read-modify-write race is returned as a
  # specifically marked stale changeset error, distinct from ordinary errors.
  defp persist(row, value) do
    result =
      row
      |> Ecto.Changeset.change(value: value, updated_at: now())
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update(stale_error_field: :lock_version)

    case result do
      {:error, changeset} -> if stale_changeset?(changeset), do: {:error, :stale}, else: result
      result -> result
    end
  end

  defp stale_changeset?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:lock_version, {_, [stale: true]}} -> true
      _ -> false
    end)
  end

  defp changeset_error_detail(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(List.wrap(messages), ", ")}"
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # ── Decoding for the public contract ──────────────────────────────────

  # Integer-typed keys decode the stored text back to an integer for the API
  # response; a malformed stored value surfaces as nil rather than raising.
  defp decode_value(key, value)
       when key in ~w(subscription_max_pause_months subscription_min_pause_days) and
              is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp decode_value(_key, value), do: value
end
