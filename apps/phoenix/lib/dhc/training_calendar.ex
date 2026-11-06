defmodule Dhc.TrainingCalendar do
  @moduledoc """
  Daily, read-only sharing of the separately managed training calendar.

  Members owns the live recipient projection. This boundary owns only grants
  it creates: existing sharing, owners, groups and manually changed rules are
  left alone. A target-scoped ledger survives source deletion and records an
  insert before Google is called, so a lost response cannot lose revocation.
  Acknowledged rules are removed only with their unchanged Google ETag.

  One session advisory lock serializes passes across nodes. It holds a checked
  out connection, but no database transaction, during bounded Google I/O. Do
  not call this operation inside a transaction or through transaction pooling.
  """

  import Ecto.Query

  alias Dhc.Auth.Principal
  alias Dhc.Members
  alias Dhc.Repo
  alias Dhc.TrainingCalendar.Google
  alias Dhc.TrainingCalendar.Grant

  @doc "Reconciles current eligibility, not a roster copied into a job. Disabled by default."
  @spec sync() :: {:ok, map() | :disabled | :busy} | {:error, atom() | map()}
  def sync do
    case target() do
      {:ok, calendar_id} -> serialize(calendar_id, fn -> reconcile(calendar_id) end)
      :disabled -> {:ok, :disabled}
      {:error, _reason} = error -> error
    end
  end

  defp target do
    config = Application.get_env(:dhc, __MODULE__, [])

    if Keyword.get(config, :enabled, false) do
      case Keyword.get(config, :calendar_id) do
        id when is_binary(id) -> validate_target(String.trim(id))
        _missing -> {:error, :configuration}
      end
    else
      :disabled
    end
  end

  # An explicit ID keeps the ledger bound to a calendar, not a mutable alias.
  defp validate_target(id) when id in ["", "primary"], do: {:error, :configuration}

  defp validate_target(id) do
    workshop = Application.get_env(:dhc, Dhc.WorkshopCalendar, [])
    protected = Keyword.take(workshop, [:committee_calendar_id, :participant_calendar_id])

    if Enum.any?(protected, fn {_audience, target} -> target == id end),
      do: {:error, :configuration},
      else: {:ok, id}
  end

  defp serialize(calendar_id, fun) do
    if Repo.in_transaction?() do
      {:error, :transaction_not_allowed}
    else
      Repo.checkout(fn -> with_session_lock(calendar_id, fun) end, timeout: :timer.minutes(30))
    end
  end

  defp with_session_lock(calendar_id, fun) do
    key = "dhc:training-calendar:" <> calendar_id

    case Repo.query!("SELECT pg_try_advisory_lock(hashtextextended($1, 0))", [key]).rows do
      [[true]] ->
        try do
          fun.()
        after
          Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [key])
        end

      [[false]] ->
        {:ok, :busy}
    end
  end

  defp reconcile(calendar_id) do
    # Never mutate from a partial or failed paginated observation.
    with {:ok, rules} <- Google.list(calendar_id),
         {:ok, observed} <- user_rules(rules) do
      desired = MapSet.new(Members.training_calendar_emails())
      grants = Repo.all(from g in Grant, where: g.calendar_id == ^calendar_id, order_by: g.email)
      result = %{added: 0, removed: 0, errors: []}

      result =
        Enum.reduce(desired, result, fn email, result ->
          check_manual_access(Map.get(observed, email), result)
        end)

      result =
        Enum.reduce(grants, result, fn grant, result ->
          reconcile_grant(grant, Map.get(observed, grant.email), desired, result)
        end)

      desired
      |> Enum.sort()
      |> Enum.reject(&Map.has_key?(observed, &1))
      |> Enum.reduce(result, &insert_missing(calendar_id, &1, &2))
      |> finish()
    end
  end

  defp check_manual_access(%{"role" => "freeBusyReader"}, result),
    do: failed(result, :insufficient_access)

  defp check_manual_access(_rule, result), do: result

  defp user_rules(rules) do
    Enum.reduce_while(rules, {:ok, %{}}, fn
      %{"role" => role, "scope" => %{"type" => "user", "value" => email}} = rule, {:ok, acc}
      when role != "none" ->
        email = Principal.normalize_email(email)

        if Map.has_key?(acc, email),
          do: {:halt, {:error, :rejected}},
          else: {:cont, {:ok, Map.put(acc, email, rule)}}

      _rule, result ->
        {:cont, result}
    end)
  end

  defp reconcile_grant(grant, nil, desired, result) do
    cond do
      MapSet.member?(desired, grant.email) ->
        result

      is_nil(grant.rule_id) ->
        # An unacknowledged insert may still arrive. Keep the cleanup obligation.
        failed(result, :uncertain_grant)

      true ->
        Repo.delete!(grant)
        result
    end
  end

  defp reconcile_grant(grant, rule, desired, result) do
    if owned_rule?(grant, rule) do
      grant = if is_nil(grant.rule_id), do: acknowledge(grant, rule), else: grant

      if MapSet.member?(desired, grant.email) do
        result
      else
        remove(grant, result)
      end
    else
      # An administrator changed/replaced our rule. It is now separately managed.
      Repo.delete!(grant)
      result
    end
  end

  defp owned_rule?(%Grant{rule_id: nil}, %{"role" => "reader"}), do: true

  defp owned_rule?(grant, rule),
    do: rule["role"] == "reader" and rule["id"] == grant.rule_id and rule["etag"] == grant.etag

  defp remove(grant, result) do
    case Google.delete(grant.calendar_id, grant.rule_id, grant.etag) do
      :ok ->
        Repo.delete!(grant)
        Map.update!(result, :removed, &(&1 + 1))

      {:error, reason} ->
        failed(result, reason)
    end
  end

  defp insert_missing(calendar_id, email, result) do
    existing = Repo.get_by(Grant, [calendar_id: calendar_id, email: email], log: false)
    uncertain? = existing != nil and is_nil(existing.rule_id)
    grant = prepare(existing, calendar_id, email)

    case Google.insert(calendar_id, email) do
      {:ok, rule} ->
        if inserted_rule?(rule, email) do
          acknowledge(grant, rule)
          Map.update!(result, :added, &(&1 + 1))
        else
          failed(result, :rejected)
        end

      {:error, reason} ->
        # A definite refusal of a fresh insert didn't create a share. A prior
        # uncertain request, however, may still arrive despite this refusal.
        if reason != :transient and not uncertain?, do: Repo.delete!(grant)
        failed(result, reason)
    end
  end

  defp prepare(nil, calendar_id, email),
    do: Repo.insert!(%Grant{calendar_id: calendar_id, email: email}, log: false)

  defp prepare(grant, _calendar_id, _email),
    do: grant |> Ecto.Changeset.change(rule_id: nil, etag: nil) |> Repo.update!(log: false)

  defp acknowledge(grant, rule) do
    grant
    |> Ecto.Changeset.change(rule_id: rule["id"], etag: rule["etag"])
    |> Repo.update!(log: false)
  end

  defp inserted_rule?(
         %{"role" => "reader", "scope" => %{"type" => "user", "value" => email}},
         expected
       ),
       do: Principal.normalize_email(email) == expected

  defp inserted_rule?(_rule, _email), do: false

  defp failed(result, reason), do: Map.update!(result, :errors, &[reason | &1])

  defp finish(%{errors: []} = result), do: {:ok, Map.delete(result, :errors)}

  defp finish(result),
    do:
      {:error,
       %{failed: length(result.errors), reasons: result.errors |> Enum.uniq() |> Enum.sort()}}
end
