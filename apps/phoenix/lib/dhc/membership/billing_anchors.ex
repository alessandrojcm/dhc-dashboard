defmodule Dhc.Membership.BillingAnchors do
  @moduledoc """
  The club's membership billing anchors (ALE-423): the monthly subscription
  bills on the 1st of each month and the annual one on the next 7 January.

  This is the one owner of those days. Subscription creation (Invitation
  Acceptance's `Dhc.Invitations.StripePayment` and `Dhc.Membership.Reactivation`)
  sends `subscription_anchor_config/1`, which Stripe resolves to the next
  occurrence of that day at the subscription's creation time-of-day UTC.
  Invoice previews cannot take that config, so they send
  `config_anchor_unix/2` — the same resolution done here for a given instant —
  and the pricing reads show `billing_starts/1`'s dates, so a preview, the
  dates a person is told and the real charge always agree.

  Every function takes the instant or date explicitly; nothing here reads the
  clock. The dates are UTC civil dates, matching how Stripe resolves the
  anchor.
  """

  @monthly_day 1
  @annual_month 1
  @annual_day 7

  @type kind :: :monthly | :annual

  @doc """
  The 1st of the month after `date`: the first monthly billing date for a
  subscription created (or starting) on `date`.
  """
  @spec monthly_start(Date.t()) :: Date.t()
  def monthly_start(%Date{year: year, month: 12}), do: Date.new!(year + 1, 1, @monthly_day)
  def monthly_start(%Date{year: year, month: month}), do: Date.new!(year, month + 1, @monthly_day)

  @doc """
  The next 7 January strictly after `date` (this year's while it is still
  ahead, otherwise next year's): the first annual billing date for a
  subscription created on `date`.
  """
  @spec annual_start(Date.t()) :: Date.t()
  def annual_start(%Date{year: year} = date) do
    candidate = Date.new!(year, @annual_month, @annual_day)

    if Date.compare(candidate, date) == :gt,
      do: candidate,
      else: Date.new!(year + 1, @annual_month, @annual_day)
  end

  @doc "The first billing date of the `kind` subscription created on `date`."
  @spec start(kind(), Date.t()) :: Date.t()
  def start(:monthly, date), do: monthly_start(date)
  def start(:annual, date), do: annual_start(date)

  @doc """
  The monthly and annual billing start dates, as `YYYY-MM-DD` civil dates,
  for a subscription created at `now` (the pricing reads' `monthlyBillingStart`
  and `annualBillingStart`).
  """
  @spec billing_starts(DateTime.t()) :: %{
          monthlyBillingStart: String.t(),
          annualBillingStart: String.t()
        }
  def billing_starts(%DateTime{} = now) do
    today = utc_date(now)

    %{
      monthlyBillingStart: Date.to_iso8601(monthly_start(today)),
      annualBillingStart: Date.to_iso8601(annual_start(today))
    }
  end

  @doc """
  The `billing_cycle_anchor_config` form fields subscription creation sends.
  Constant, so idempotent retries of a creation stay byte-stable.
  """
  @spec subscription_anchor_config(kind()) :: [{String.t(), String.t()}]
  def subscription_anchor_config(:monthly),
    do: [{"billing_cycle_anchor_config[day_of_month]", Integer.to_string(@monthly_day)}]

  def subscription_anchor_config(:annual),
    do: [
      {"billing_cycle_anchor_config[month]", Integer.to_string(@annual_month)},
      {"billing_cycle_anchor_config[day_of_month]", Integer.to_string(@annual_day)}
    ]

  @doc """
  The Unix anchor Stripe resolves `subscription_anchor_config(kind)` to for a
  subscription created at `now`: the `kind`'s start date at `now`'s UTC
  time-of-day (whole seconds). Invoice previews send it as
  `billing_cycle_anchor` so they prorate exactly like the real subscription.
  """
  @spec config_anchor_unix(kind(), DateTime.t()) :: integer()
  def config_anchor_unix(kind, %DateTime{} = now) do
    utc = DateTime.shift_zone!(now, "Etc/UTC")
    time = %{DateTime.to_time(utc) | microsecond: {0, 0}}

    kind
    |> start(DateTime.to_date(utc))
    |> DateTime.new!(time, "Etc/UTC")
    |> DateTime.to_unix()
  end

  @doc """
  Midnight UTC of `date` as a Unix timestamp. Deterministic for a whole day,
  so it is the form to use where an idempotent request must stay byte-stable
  across retries (Reactivation's explicit anchors and trial ends).
  """
  @spec midnight_unix(Date.t()) :: integer()
  def midnight_unix(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp utc_date(now), do: now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
end
