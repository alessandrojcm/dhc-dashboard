defmodule Dhc.Invitations.Pricing do
  @moduledoc """
  Public invitation signup pricing.

  Ports the SvelteKit `PricingService` Stripe invoice-preview calculation to
  Phoenix while preserving the DTO consumed by the signup UI.

  ADR 0013 makes pricing read-only. Invoice previews are calculated for a
  prospective subscription without creating or persisting a Stripe Customer.
  """

  alias Dhc.Stripe.LookupKeys
  alias Dhc.Stripe.Operations

  @migration_code "DHCDASHBOARD"
  @currency "EUR"

  @doc false
  def preview_membership(coupon_code \\ nil) do
    with {:ok, prices} <- membership_price_ids(),
         {:ok, promotion} <- resolve_promotion(coupon_code),
         {:ok, details} <- pricing_details(prices, promotion) do
      {:ok, generate_pricing_info(details)}
    end
  end

  @doc false
  def complimentary_preview do
    zero = money(0)

    %{
      complimentary: true,
      proratedPrice: zero,
      proratedMonthlyPrice: zero,
      proratedAnnualPrice: zero,
      monthlyFee: zero,
      annualFee: zero,
      discountPercentage: 100
    }
  end

  def membership_payment_plan(coupon_code \\ nil)

  def membership_payment_plan({:coupon, _coupon_id, [:monthly, :annual]} = coupon) do
    with {:ok, prices} <- membership_price_ids(),
         {:ok, promotion} <- resolve_promotion(coupon),
         :ok <- validate_complimentary_coupon(promotion.coupon) do
      {:ok,
       %{
         requirement: :complimentary,
         monthly_price_id: prices.monthly.id,
         annual_price_id: prices.annual.id,
         coupon_id: promotion.coupon_id,
         promotion_code_id: nil,
         migration?: false,
         discount_targets: [:monthly, :annual]
       }}
    end
  end

  def membership_payment_plan(coupon_code) do
    with {:ok, prices} <- membership_price_ids(),
         {:ok, promotion} <- resolve_promotion(coupon_code),
         {:ok, details} <- pricing_details(prices, promotion) do
      complimentary? =
        migration_promotion?(promotion) or
          Enum.all?(
            [
              details.prorated_monthly_price,
              details.prorated_annual_price,
              details.monthly_amount_due,
              details.annual_amount_due
            ],
            &(&1 == 0)
          )

      {:ok,
       %{
         requirement: if(complimentary?, do: :complimentary, else: :paid),
         monthly_price_id: prices.monthly.id,
         annual_price_id: prices.annual.id,
         coupon_id: promotion.coupon_id,
         promotion_code_id: promotion.promotion_code_id,
         migration?: promotion.migration?,
         discount_targets: discount_targets(promotion, prices)
       }}
    end
  end

  @doc """
  Resolves the private Stripe coupon ID configured for an invitation pricing tier.

  The coupon shapes live in the Stripe dashboard — `coach`: percent_off 100,
  duration forever (both subscriptions invoice at zero forever); `student`:
  percent_off 20, duration forever, scoped to the monthly product. Tier coupons
  are applied directly by the backend and never exposed as customer-facing codes.
  """
  @spec tier_coupon_id(:coach | :student) ::
          {:ok, {:coupon, String.t(), [:monthly | :annual]}}
          | {:error, :tier_coupon_not_configured}
  def tier_coupon_id(tier) when tier in [:coach, :student] do
    case Application.get_env(:dhc, :membership_tier_coupons, []) |> Keyword.get(tier) do
      id when is_binary(id) and id != "" -> {:ok, {:coupon, id, tier_discount_targets(tier)}}
      _ -> {:error, :tier_coupon_not_configured}
    end
  end

  defp tier_discount_targets(:coach), do: [:monthly, :annual]
  defp tier_discount_targets(:student), do: [:monthly]

  # Coupons restricted to specific products must not be attached to
  # subscriptions outside their scope — Stripe rejects the request at
  # creation time. Unrestricted coupons apply to both subscriptions.
  defp discount_targets(%{discount_targets: targets}, _prices) when is_list(targets), do: targets

  defp discount_targets(%{coupon: %{"applies_to" => %{"products" => products}}}, prices)
       when is_list(products) do
    Enum.filter([:monthly, :annual], fn kind ->
      price = Map.fetch!(prices, kind)
      price.product in products
    end)
  end

  defp discount_targets(_promotion, _prices), do: [:monthly, :annual]

  @doc false
  def membership_price_ids do
    with {:ok, monthly} <- price_id_for_lookup_key(LookupKeys.monthly()),
         {:ok, annual} <- price_id_for_lookup_key(LookupKeys.annual()) do
      {:ok, %{monthly: monthly, annual: annual}}
    end
  end

  defp price_id_for_lookup_key(lookup_key) do
    case Operations.get_prices(%{}, lookup_keys: [lookup_key], active: true, limit: 1) do
      {:ok, %{"data" => [%{"id" => id, "product" => product} | _]}}
      when is_binary(id) and is_binary(product) ->
        {:ok, %{id: id, product: product}}

      {:ok, %{"data" => []}} ->
        {:error, :price_not_found}

      {:error, reason} ->
        {:error, {:stripe, reason}}

      _ ->
        {:error, :invalid_price_response}
    end
  end

  @doc false
  def resolve_promotion(nil),
    do:
      {:ok, %{code: nil, coupon_id: nil, promotion_code_id: nil, coupon: nil, migration?: false}}

  def resolve_promotion(""), do: resolve_promotion(nil)

  def resolve_promotion({:coupon, coupon_id, discount_targets})
      when is_binary(coupon_id) and coupon_id != "" and is_list(discount_targets) do
    with {:ok, coupon} <- retrieve_coupon(coupon_id),
         :ok <- validate_coupon(coupon) do
      {:ok,
       %{
         code: nil,
         coupon_id: coupon_id,
         promotion_code_id: nil,
         coupon: coupon,
         discount_targets: discount_targets,
         migration?: false
       }}
    end
  end

  def resolve_promotion(coupon_code) when is_binary(coupon_code) do
    trimmed = String.trim(coupon_code)

    if trimmed == "" do
      resolve_promotion(nil)
    else
      fetch_promotion(trimmed)
    end
  end

  defp fetch_promotion(code) do
    case Operations.get_promotion_codes(%{}, active: true, code: code, limit: 1) do
      {:ok, %{"data" => [%{"id" => id, "promotion" => %{"coupon" => coupon_id}} | _]}}
      when is_binary(id) and is_binary(coupon_id) ->
        build_promotion(code, id, coupon_id)

      {:ok, %{"data" => []}} ->
        {:error, :invalid_promotion_code}

      {:error, reason} ->
        {:error, {:stripe, reason}}

      _ ->
        {:error, :invalid_promotion_code_response}
    end
  end

  defp build_promotion(code, id, coupon_id) do
    if migration_code?(code) do
      {:ok,
       %{
         code: code,
         coupon_id: nil,
         promotion_code_id: nil,
         coupon: %{migration?: true},
         migration?: true
       }}
    else
      with {:ok, coupon} <- retrieve_coupon(coupon_id),
           :ok <- validate_coupon(coupon) do
        {:ok,
         %{
           code: code,
           coupon_id: nil,
           promotion_code_id: id,
           coupon: coupon,
           migration?: false
         }}
      end
    end
  end

  defp retrieve_coupon(coupon_id) do
    case Operations.get_coupons_coupon(coupon_id, %{}) do
      {:ok, coupon} ->
        {:ok, coupon}

      {:error, reason} ->
        {:error, {:stripe, reason}}
    end
  end

  defp validate_coupon(%{"duration" => "forever", "amount_off" => amount_off})
       when is_integer(amount_off) do
    {:error, :forever_amount_coupon}
  end

  defp validate_coupon(_coupon), do: :ok

  defp validate_complimentary_coupon(%{
         "duration" => "forever",
         "percent_off" => percent_off
       })
       when percent_off == 100,
       do: :ok

  defp validate_complimentary_coupon(_coupon), do: {:error, :invalid_complimentary_coupon}

  defp pricing_details(prices, promotion) do
    next_month = next_month_anchor()
    next_january = next_january_anchor()

    calls = [
      monthly_initial: fn ->
        preview_invoice(
          prices.monthly.id,
          :billing_cycle_anchor,
          next_month,
          promotion_for_preview(promotion, prices.monthly, :monthly, :initial)
        )
      end,
      annual_initial: fn ->
        preview_invoice(
          prices.annual.id,
          :billing_cycle_anchor,
          next_january,
          promotion_for_preview(promotion, prices.annual, :annual, :initial)
        )
      end,
      monthly_recurring: fn ->
        preview_invoice(
          prices.monthly.id,
          :start_date,
          next_month,
          promotion_for_preview(promotion, prices.monthly, :monthly, :recurring)
        )
      end,
      annual_recurring: fn ->
        preview_invoice(
          prices.annual.id,
          :start_date,
          next_january,
          promotion_for_preview(promotion, prices.annual, :annual, :recurring)
        )
      end
    ]

    previews =
      calls
      |> Task.async_stream(
        fn {name, preview} -> {name, preview.()} end,
        ordered: false,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, result} -> result end)

    with {:ok, initial_monthly} <- Map.fetch!(previews, :monthly_initial),
         {:ok, initial_annual} <- Map.fetch!(previews, :annual_initial),
         {:ok, next_month_invoice} <- Map.fetch!(previews, :monthly_recurring),
         {:ok, next_january_invoice} <- Map.fetch!(previews, :annual_recurring) do
      monthly_discount = total_discount(next_month_invoice)
      annual_discount = total_discount(next_january_invoice)
      initial_monthly_discount = total_discount(initial_monthly)
      initial_annual_discount = total_discount(initial_annual)

      discount_percentage =
        cond do
          migration_promotion?(promotion) ->
            100

          initial_monthly_discount > 0 ->
            discount_percentage(initial_monthly_discount, amount(initial_monthly, "subtotal"))

          initial_annual_discount > 0 ->
            discount_percentage(initial_annual_discount, amount(initial_annual, "subtotal"))

          monthly_discount > 0 ->
            discount_percentage(monthly_discount, amount(next_month_invoice, "subtotal"))

          true ->
            0
        end

      prorated_monthly_price = amount(initial_monthly, "amount_due")
      prorated_annual_price = amount(initial_annual, "amount_due")

      prorated_price =
        one_time_price(prorated_monthly_price, promotion, prices.monthly) +
          one_time_price(prorated_annual_price, promotion, prices.annual)

      {:ok,
       %{
         prorated_price: if(migration_promotion?(promotion), do: 0, else: prorated_price),
         monthly_fee: amount(next_month_invoice, "subtotal"),
         annual_fee: amount(next_january_invoice, "subtotal"),
         monthly_amount_due: amount(next_month_invoice, "amount_due"),
         annual_amount_due: amount(next_january_invoice, "amount_due"),
         discount_percentage: discount_percentage,
         coupon: promotion.code,
         discounted_monthly_fee:
           if(monthly_discount > 0, do: amount(next_month_invoice, "amount_due"), else: nil),
         discounted_annual_fee:
           if(annual_discount > 0, do: amount(next_january_invoice, "amount_due"), else: nil),
         prorated_annual_price: prorated_annual_price,
         prorated_monthly_price: prorated_monthly_price,
         coupon_details: promotion.coupon
       }}
    end
  end

  defp preview_invoice(price_id, date_key, unix_anchor, promotion) do
    form =
      %{
        "subscription_details[items][0][price]" => price_id,
        "subscription_details[items][0][quantity]" => "1",
        "subscription_details[#{date_key}]" => Integer.to_string(unix_anchor)
      }
      |> maybe_add_discount(promotion)

    case Operations.post_invoices_create_preview(form) do
      {:ok, invoice} -> {:ok, invoice}
      {:error, reason} -> {:error, {:stripe, reason}}
    end
  end

  defp maybe_add_discount(form, %{coupon_id: coupon_id}) when is_binary(coupon_id),
    do: Map.put(form, "discounts[0][coupon]", coupon_id)

  defp maybe_add_discount(form, %{promotion_code_id: nil}), do: form

  defp maybe_add_discount(form, %{promotion_code_id: promotion_code_id}),
    do: Map.put(form, "discounts[0][promotion_code]", promotion_code_id)

  defp promotion_for_preview(
         %{coupon: %{"duration" => "once"}} = promotion,
         _price,
         _kind,
         _phase
       ),
       do: %{promotion | coupon_id: nil, promotion_code_id: nil}

  defp promotion_for_preview(
         %{discount_targets: targets} = promotion,
         _price,
         kind,
         _phase
       )
       when is_list(targets) do
    if kind in targets,
      do: promotion,
      else: %{promotion | coupon_id: nil, promotion_code_id: nil}
  end

  defp promotion_for_preview(
         %{coupon: %{"applies_to" => %{"products" => products}}} = promotion,
         %{product: product},
         _kind,
         _phase
       )
       when is_list(products) do
    if product in products,
      do: promotion,
      else: %{promotion | coupon_id: nil, promotion_code_id: nil}
  end

  defp promotion_for_preview(promotion, _price, _kind, _phase), do: promotion

  defp one_time_price(
         amount,
         %{coupon: %{"duration" => "once", "percent_off" => percent_off}} = promotion,
         price
       )
       when is_number(percent_off) do
    if promotion_applies_to_price?(promotion, price) do
      round(amount * (100 - percent_off) / 100)
    else
      amount
    end
  end

  defp one_time_price(amount, _promotion, _price), do: amount

  defp promotion_applies_to_price?(
         %{coupon: %{"applies_to" => %{"products" => products}}},
         %{product: product}
       )
       when is_list(products),
       do: product in products

  defp promotion_applies_to_price?(_promotion, _price), do: true

  defp total_discount(%{"total_discount_amounts" => discounts}) when is_list(discounts) do
    Enum.reduce(discounts, 0, fn discount, sum -> sum + amount(discount, "amount") end)
  end

  defp total_discount(_invoice), do: 0

  defp amount(map, key), do: Map.get(map, key, 0) || 0

  defp discount_percentage(_discount, 0), do: 0
  defp discount_percentage(discount, subtotal), do: round(discount / subtotal * 100)

  defp generate_pricing_info(
         %{coupon_details: %{"duration" => "once", "percent_off" => percent_off}} = details
       )
       when is_number(percent_off) do
    details
    |> Map.put(:discount_percentage, percent_off)
    |> Map.put(:discounted_monthly_fee, nil)
    |> Map.put(:discounted_annual_fee, nil)
    |> Map.delete(:coupon_details)
    |> generate_pricing_info()
  end

  defp generate_pricing_info(details) do
    %{
      proratedPrice: money(details.prorated_price),
      proratedMonthlyPrice: money(details.prorated_monthly_price),
      proratedAnnualPrice: money(details.prorated_annual_price),
      monthlyFee: money(details.monthly_fee),
      annualFee: money(details.annual_fee),
      discountPercentage: details.discount_percentage
    }
    |> maybe_put_money(:discountedMonthlyFee, details.discounted_monthly_fee)
    |> maybe_put_money(:discountedAnnualFee, details.discounted_annual_fee)
    |> maybe_put(:coupon, details.coupon)
  end

  defp money(amount), do: %{amount: amount, currency: @currency, precision: 2}

  defp maybe_put_money(map, _key, nil), do: map
  defp maybe_put_money(map, key, amount), do: Map.put(map, key, money(amount))

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp migration_promotion?(%{coupon: %{migration?: true}}), do: true
  defp migration_promotion?(_promotion), do: false

  defp migration_code?(code),
    do: String.downcase(String.trim(code)) == String.downcase(String.trim(migration_code()))

  defp migration_code do
    Application.get_env(:dhc, :dashboard_migration_code, @migration_code)
  end

  defp next_month_anchor do
    today = Date.utc_today()
    {year, month} = add_month(today.year, today.month)
    date_to_unix!(Date.new!(year, month, 1))
  end

  defp next_january_anchor do
    today = Date.utc_today()
    date_to_unix!(Date.new!(today.year + 1, 1, 6))
  end

  defp add_month(year, 12), do: {year + 1, 1}
  defp add_month(year, month), do: {year, month + 1}

  defp date_to_unix!(date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end
end
