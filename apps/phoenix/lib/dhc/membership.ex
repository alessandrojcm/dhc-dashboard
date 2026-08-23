defmodule Dhc.Membership do
  @moduledoc """
  Membership context functions for subscription/access state.

  Stripe is the source of truth for pause/resume commands. We only update the
  local `member_profiles.subscription_paused_until` projection after Stripe
  confirms the requested subscription mutation.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Membership.Reactivation
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Members
  alias Dhc.Repo
  alias Dhc.Stripe.LookupKeys
  alias Dhc.Stripe.Operations
  alias Dhc.UserProfiles.UserProfile

  require Logger

  @type pause_error ::
          :invalid_payload
          | :not_found
          | :subscription_not_found
          | :stripe_error
          | Ecto.Changeset.t()

  @type reactivate_error ::
          :invalid_payload
          | :not_found
          | :membership_active
          | :membership_paused
          | :no_saved_payment_method
          | :stripe_error

  # A subscription covers its price when active or awaiting a future start
  # (`trialing`) — same coverage rule the Stripe sync applies (ALE-250).
  @covering_statuses ["active", "trialing"]

  @max_start_date_days_ahead 366

  @doc """
  Pauses a member's active Stripe membership subscription until `pause_until`.
  """
  @spec pause(String.t(), map()) :: {:ok, map()} | {:error, pause_error()}
  def pause(member_id, %{"pauseUntil" => pause_until}) when is_binary(pause_until) do
    with {:ok, pause_until} <- parse_pause_until(pause_until),
         {:ok, member} <- load_member_customer(member_id),
         {:ok, subscription} <- find_membership_subscription(member.customer_id, :active),
         {:ok, updated_subscription} <- pause_stripe_subscription(subscription, pause_until),
         {:ok, confirmed_until} <- confirmed_pause_until(updated_subscription) do
      write_pause_until(member_id, confirmed_until)
    end
  end

  def pause(_member_id, _attrs), do: {:error, :invalid_payload}

  @doc """
  Resumes a member's paused Stripe membership subscription.
  """
  @spec resume(String.t()) ::
          {:ok, map()} | {:error, :not_found | :subscription_not_found | :stripe_error}
  def resume(member_id) do
    with {:ok, member} <- load_member_customer(member_id),
         :ok <- ensure_locally_paused(member),
         {:ok, subscription} <- find_membership_subscription(member.customer_id, :paused),
         {:ok, _updated_subscription} <- resume_stripe_subscription(subscription) do
      write_pause_until(member_id, nil)
    end
  end

  @doc """
  Reactivates an inactive member by ensuring they have live monthly + annual
  membership subscriptions against their saved SEPA payment method (ALE-251).
  If one subscription is still active, it is reused and only the lapsed one is
  recreated.

  Stripe is the source of truth (ADR-0008): the guard lists the customer's
  live subscriptions, so a member whose local `is_active` flag lags behind a
  still-active Stripe subscription is rejected with `:membership_active`.
  Retries with identical params are idempotent — Stripe idempotency keys are
  derived from member id + requested start date + annual fee mode, so a retry
  after switching modes reaches Stripe as fresh requests instead of replaying
  the other mode's stored responses.
  """
  @spec reactivate(String.t(), map()) :: {:ok, map()} | {:error, reactivate_error()}
  def reactivate(member_id, %{"startDate" => start_date} = attrs) when is_binary(start_date) do
    with {:ok, member} <- load_member_customer(member_id),
         {:ok, parsed_start_date} <- parse_start_date(start_date),
         {:ok, annual_fee_mode} <- parse_annual_fee_mode(attrs["annualFeeMode"]),
         {:ok, existing_subscriptions} <-
           ensure_reactivatable(member.customer_id, Date.to_iso8601(parsed_start_date)),
         {:ok, result} <-
           Reactivation.activate(%{
             member_id: member.id,
             customer_id: member.customer_id,
             operator_principal_id: Map.get(attrs, "operatorPrincipalId"),
             start_date: parsed_start_date,
             annual_fee_mode: annual_fee_mode,
             existing_subscriptions: existing_subscriptions
           }) do
      restore_member_access(member_id, member.profile_id)
      {:ok, result}
    end
  end

  def reactivate(_member_id, _attrs), do: {:error, :invalid_payload}

  # Restores dashboard access immediately after a successful reactivation
  # (ALE-252). The Stripe sync stays authoritative and will reconcile this
  # flag on later runs; writing it here means the operator sees the member as
  # active without waiting for the daily cron or a webhook round-trip.
  defp restore_member_access(member_id, profile_id) do
    case Auth.apply_member_access(profile_id, true) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[membership] Failed to restore member access after reactivation for profile #{profile_id}",
          member_id: member_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Previews the saved SEPA payment method a reactivation would charge (ALE-252).

  Read-only companion to `reactivate/2` backing the operator modal: performs
  no Stripe mutation and no reactivatability guard, so the command's guards
  stay authoritative at POST time. `savedPaymentMethod` is `nil` when the
  customer has no usable saved SEPA method; the UI offers the billing portal
  fallback in that case.
  """
  @spec reactivation_preview(String.t()) ::
          {:ok, map()} | {:error, :not_found | :stripe_error}
  def reactivation_preview(member_id) do
    with {:ok, member} <- load_member_customer(member_id),
         {:ok, saved_method} <- Reactivation.saved_sepa_method(member.customer_id),
         {:ok, subscriptions} <- list_customer_subscriptions(member.customer_id) do
      coverage = covering_subscriptions_by_kind(subscriptions)

      {:ok,
       %{
         memberId: member.id,
         savedPaymentMethod: payment_method_summary(saved_method),
         membershipCoverage: membership_coverage_summary(coverage)
       }}
    end
  end

  defp payment_method_summary(nil), do: nil

  defp payment_method_summary(%{id: id, last4: last4, bank_code: bank_code, country: country}) do
    summary = %{id: id, last4: last4, country: country}

    case bank_code do
      nil -> summary
      code -> Map.put(summary, :bankCode, code)
    end
  end

  @doc """
  Previews the Stripe-computed amounts a reactivation starting on the given
  start date would charge (ALE-254).

  Backing read for the operator modal's pre-confirmation cost preview:
  performs no Stripe mutation and no reactivatability or saved-method checks,
  so it can fail independently of `reactivation_preview/2` and the command's
  guards stay authoritative at POST time. All amounts come from Stripe
  invoice previews — never local arithmetic. The optional `annualFeeMode`
  mirrors the command's annual fee choice (ALE-253): in `deferred_next_year`
  mode nothing is charged for the annual fee today.
  """
  @spec reactivation_amounts_preview(String.t(), map()) ::
          {:ok, map()} | {:error, :invalid_payload | :not_found | :stripe_error}
  def reactivation_amounts_preview(member_id, %{} = params) do
    # The member load doubles as the 404 guard; amounts themselves are
    # customer-independent (lookup-key prices + date anchors).
    with {:ok, member} <- load_member_customer(member_id),
         {:ok, parsed_start_date} <- parse_start_date(Map.get(params, "startDate")),
         {:ok, annual_fee_mode} <- parse_annual_fee_mode(params["annualFeeMode"]),
         {:ok, subscriptions} <- list_customer_subscriptions(member.customer_id) do
      active_kinds =
        subscriptions
        |> covering_subscriptions_by_kind()
        |> Map.keys()

      Reactivation.preview_amounts(parsed_start_date, annual_fee_mode, active_kinds)
    end
  end

  def reactivation_amounts_preview(_member_id, _params), do: {:error, :invalid_payload}

  @doc "Creates a short-lived Stripe Billing Portal session for a member."
  @spec create_billing_portal_session(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_payload | :not_found | :stripe_error}
  def create_billing_portal_session(member_id, return_url) do
    with :ok <- validate_return_url(return_url),
         {:ok, member} <- load_member_customer(member_id),
         {:ok, %{"url" => url}} <-
           Operations.post_billing_portal_sessions(%{
             "customer" => member.customer_id,
             "return_url" => return_url
           }) do
      {:ok, url}
    else
      {:error, reason} when reason in [:invalid_payload, :not_found] ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[membership] Stripe billing portal session failed",
          member_id: member_id,
          reason: inspect(reason)
        )

        {:error, :stripe_error}

      _ ->
        {:error, :stripe_error}
    end
  end

  defp validate_return_url(return_url) when is_binary(return_url) do
    case URI.parse(return_url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, :invalid_payload}
    end
  end

  defp validate_return_url(_return_url), do: {:error, :invalid_payload}

  defp parse_pause_until(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         :ok <- validate_pause_window(datetime) do
      {:ok, DateTime.truncate(datetime, :second)}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp parse_start_date(value) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         :ok <- validate_start_date_range(date) do
      {:ok, date}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp parse_start_date(_value), do: {:error, :invalid_payload}

  # Absent field defaults to the initial-release behaviour (prorated now);
  # anything other than the two known modes is a 422. Explicit clauses keep
  # user input away from String.to_atom.
  defp parse_annual_fee_mode(nil), do: {:ok, :prorated_now}
  defp parse_annual_fee_mode("prorated_now"), do: {:ok, :prorated_now}
  defp parse_annual_fee_mode("deferred_next_year"), do: {:ok, :deferred_next_year}
  defp parse_annual_fee_mode(_value), do: {:error, :invalid_payload}

  defp validate_start_date_range(date) do
    today = Date.utc_today()
    max = Date.add(today, @max_start_date_days_ahead)

    if Date.compare(date, today) == :lt or Date.compare(date, max) == :gt do
      {:error, :out_of_range}
    else
      :ok
    end
  end

  # Rejects members whose Stripe customer still holds complete live membership
  # coverage (active or trialing) or a paused subscription. Partial coverage is
  # returned by price kind so reactivation can reuse it and create only the
  # missing subscription. Stripe is authoritative — the local `is_active`
  # projection may lag behind it.
  #
  # Subscriptions tagged as belonging to THIS reactivation (same purpose and
  # start date) are exempt: an identical retry must reach Stripe's idempotency
  # layer and replay the stored responses instead of being rejected — this is
  # also what recovers a partially-completed reactivation.
  defp ensure_reactivatable(customer_id, start_date_iso) do
    case list_customer_subscriptions(customer_id) do
      {:ok, subscriptions} ->
        existing_subscriptions =
          subscriptions
          |> Enum.filter(fn subscription ->
            covering_membership_subscription?(subscription) and
              not owned_by_this_reactivation?(subscription, start_date_iso)
          end)
          |> covering_subscriptions_by_kind()

        cond do
          Enum.any?(subscriptions, &paused_membership_subscription?/1) ->
            {:error, :membership_paused}

          complete_membership_coverage?(existing_subscriptions) ->
            {:error, :membership_active}

          true ->
            {:ok, existing_subscriptions}
        end

      {:error, :stripe_error} = error ->
        error
    end
  end

  defp list_customer_subscriptions(customer_id) do
    case Operations.get_subscriptions(%{}, customer: customer_id, status: "all", limit: 100) do
      {:ok, %{"data" => subscriptions}} when is_list(subscriptions) ->
        {:ok, subscriptions}

      {:error, reason} ->
        Logger.error("[membership] Stripe subscription lookup failed",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, :stripe_error}

      other ->
        Logger.error("[membership] Unexpected Stripe subscription response",
          customer_id: customer_id,
          reason: inspect(other)
        )

        {:error, :stripe_error}
    end
  end

  defp owned_by_this_reactivation?(subscription, start_date_iso) do
    metadata = Map.get(subscription, "metadata", %{})

    metadata["purpose"] == Reactivation.purpose() and
      metadata["reactivation_start_date"] == start_date_iso
  end

  defp paused_membership_subscription?(subscription) do
    membership_price_subscription?(subscription) and
      not is_nil(Map.get(subscription, "pause_collection"))
  end

  defp covering_membership_subscription?(subscription) do
    membership_price_subscription?(subscription) and
      Map.get(subscription, "status") in @covering_statuses
  end

  defp covering_subscriptions_by_kind(subscriptions) do
    subscriptions
    |> Enum.filter(&covering_membership_subscription?/1)
    |> Enum.reduce(%{}, fn subscription, coverage ->
      subscription
      |> membership_subscription_kinds()
      |> Enum.reduce(coverage, &Map.put_new(&2, &1, subscription))
    end)
  end

  defp membership_subscription_kinds(subscription) do
    monthly_lookup_key = LookupKeys.monthly()
    annual_lookup_key = LookupKeys.annual()

    subscription
    |> get_in(["items", "data"])
    |> List.wrap()
    |> Enum.flat_map(fn item ->
      case get_in(item, ["price", "lookup_key"]) do
        ^monthly_lookup_key -> [:monthly]
        ^annual_lookup_key -> [:annual]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end

  defp complete_membership_coverage?(subscriptions) do
    Map.has_key?(subscriptions, :monthly) and Map.has_key?(subscriptions, :annual)
  end

  defp membership_coverage_summary(subscriptions) do
    %{
      monthly: coverage_status(subscriptions, :monthly),
      annual: coverage_status(subscriptions, :annual)
    }
  end

  defp coverage_status(subscriptions, kind) do
    if Map.has_key?(subscriptions, kind), do: "active", else: "lapsed"
  end

  defp membership_price_subscription?(%{"items" => %{"data" => items}}) when is_list(items) do
    Enum.any?(items, fn item ->
      get_in(item, ["price", "lookup_key"]) in [LookupKeys.monthly(), LookupKeys.annual()]
    end)
  end

  defp membership_price_subscription?(_subscription), do: false

  defp validate_pause_window(datetime) do
    now = DateTime.utc_now()
    min = DateTime.add(now, 1, :day)

    max_date = Date.shift(DateTime.to_date(now), month: 6)
    {:ok, max} = DateTime.new(max_date, DateTime.to_time(now), "Etc/UTC")

    if DateTime.compare(datetime, min) == :gt and DateTime.compare(datetime, max) == :lt do
      :ok
    else
      {:error, :invalid_payload}
    end
  end

  defp load_member_customer(member_id) do
    query =
      from m in MemberProfile,
        join: p in UserProfile,
        on: p.id == m.user_profile_id,
        where: m.id == ^member_id,
        select: %{
          id: m.id,
          profile_id: p.id,
          customer_id: p.customer_id,
          subscription_paused_until: m.subscription_paused_until
        }

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %{customer_id: customer_id} when is_nil(customer_id) or customer_id == "" ->
        {:error, :not_found}

      member ->
        {:ok, member}
    end
  end

  defp ensure_locally_paused(%{subscription_paused_until: nil}),
    do: {:error, :subscription_not_found}

  defp ensure_locally_paused(_member), do: :ok

  defp find_membership_subscription(customer_id, mode) do
    opts = [customer: customer_id, limit: 10]
    opts = if mode == :active, do: Keyword.put(opts, :status, "active"), else: opts

    case Operations.get_subscriptions(%{}, opts) do
      {:ok, %{"data" => subscriptions}} ->
        case Enum.find(subscriptions, &membership_subscription?(&1, mode)) do
          nil -> {:error, :subscription_not_found}
          subscription -> {:ok, subscription}
        end

      {:error, reason} ->
        Logger.error("[membership] Stripe subscription list failed",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, :stripe_error}
    end
  end

  defp membership_subscription?(subscription, :active) do
    has_membership_price?(subscription) and subscription["status"] == "active"
  end

  defp membership_subscription?(subscription, :paused) do
    has_membership_price?(subscription) and not is_nil(subscription["pause_collection"])
  end

  defp has_membership_price?(%{"items" => %{"data" => items}}) when is_list(items) do
    Enum.any?(items, fn item ->
      get_in(item, ["price", "lookup_key"]) == LookupKeys.monthly()
    end)
  end

  defp has_membership_price?(_subscription), do: false

  defp pause_stripe_subscription(%{"id" => subscription_id}, pause_until) do
    resumes_at = DateTime.to_unix(pause_until)

    body = %{
      "pause_collection[behavior]" => "void",
      "pause_collection[resumes_at]" => resumes_at
    }

    case Operations.post_subscriptions_subscription_exposed_id(subscription_id, body) do
      {:ok, subscription} ->
        {:ok, subscription}

      {:error, reason} ->
        Logger.error("[membership] Stripe subscription pause failed",
          subscription_id: subscription_id,
          reason: inspect(reason)
        )

        {:error, :stripe_error}
    end
  end

  defp resume_stripe_subscription(%{"id" => subscription_id}) do
    case Operations.post_subscriptions_subscription_exposed_id(subscription_id, %{
           "pause_collection" => ""
         }) do
      {:ok, subscription} ->
        {:ok, subscription}

      {:error, reason} ->
        Logger.error("[membership] Stripe subscription resume failed",
          subscription_id: subscription_id,
          reason: inspect(reason)
        )

        {:error, :stripe_error}
    end
  end

  defp confirmed_pause_until(%{"pause_collection" => %{"resumes_at" => resumes_at}})
       when is_integer(resumes_at) do
    {:ok, DateTime.from_unix!(resumes_at)}
  end

  defp confirmed_pause_until(_subscription), do: {:error, :stripe_error}

  defp write_pause_until(member_id, pause_until) do
    Repo.transaction(fn ->
      member_profile = Repo.get(MemberProfile, member_id)

      if is_nil(member_profile) do
        Repo.rollback(:not_found)
      end

      member_profile
      |> Ecto.Changeset.change(subscription_paused_until: pause_until)
      |> Repo.update()
      |> case do
        {:ok, _profile} ->
          load_updated_member(member_id)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp load_updated_member(member_id) do
    case Members.get_member(member_id) do
      {:ok, member} -> member
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
