defmodule Dhc.Membership do
  @moduledoc """
  Membership context functions for subscription/access state.

  Stripe is the source of truth for pause/resume commands. We only update the
  local `member_profiles.subscription_paused_until` projection after Stripe
  confirms the requested subscription mutation.
  """

  import Ecto.Query

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Members
  alias Dhc.Repo
  alias Dhc.Stripe.Operations
  alias Dhc.UserProfiles.UserProfile

  require Logger

  @membership_lookup_key "standard_membership_fee"

  @type pause_error ::
          :invalid_payload
          | :not_found
          | :subscription_not_found
          | :stripe_error
          | Ecto.Changeset.t()

  @doc """
  Pauses a member's active Stripe membership subscription until `pause_until`.
  """
  @spec pause(String.t(), map()) :: {:ok, map()} | {:error, pause_error()}
  def pause(member_id, %{"pauseUntil" => pause_until}) when is_binary(pause_until) do
    with {:ok, pause_until} <- parse_pause_until(pause_until),
         {:ok, member} <- load_member_customer(member_id),
         {:ok, subscription} <- find_membership_subscription(member.customer_id, :active),
         {:ok, updated_subscription} <- pause_stripe_subscription(subscription, pause_until),
         {:ok, confirmed_until} <- confirmed_pause_until(updated_subscription),
         {:ok, updated_member} <- write_pause_until(member_id, confirmed_until) do
      {:ok, updated_member}
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
         {:ok, _updated_subscription} <- resume_stripe_subscription(subscription),
         {:ok, updated_member} <- write_pause_until(member_id, nil) do
      {:ok, updated_member}
    end
  end

  defp parse_pause_until(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         :ok <- validate_pause_window(datetime) do
      {:ok, DateTime.truncate(datetime, :second)}
    else
      _ -> {:error, :invalid_payload}
    end
  end

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
      get_in(item, ["price", "lookup_key"]) == @membership_lookup_key
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

      case Ecto.Changeset.change(member_profile, subscription_paused_until: pause_until)
           |> Repo.update() do
        {:ok, _profile} ->
          case Members.get_member(member_id) do
            {:ok, member} -> member
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end
end
