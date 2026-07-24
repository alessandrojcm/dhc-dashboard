defmodule Dhc.Invitations.Pricing do
  @moduledoc """
  Public invitation signup pricing.

  Ports the SvelteKit `PricingService` Stripe invoice-preview calculation to
  Phoenix while preserving the DTO consumed by the signup UI.

  ALE-162 (ADR 0010): issue time no longer creates a `user_profiles` row or a
  Stripe customer, so there is no `customer_id` to look up at pricing time.
  The pricing endpoint lazily creates a Stripe customer on first preview (or
  reuses `invitation.stripe_customer_id` if a prior pricing call already
  attached one) and persists it on the invitation row. Acceptance then
  reuses the same customer.
  """

  import Ecto.Query

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.Repository
  alias Dhc.Repo
  alias Dhc.Stripe.LookupKeys
  alias Dhc.Stripe.Operations

  @migration_code "DHCDASHBOARD"
  @currency "EUR"

  @spec pricing_for_invitation(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom() | {:stripe, term()}}
  def pricing_for_invitation(invitation_id, coupon_code \\ nil) do
    with {:ok, invitation} <- pending_invitation(invitation_id),
         {:ok, customer_id} <- resolve_customer_id(invitation),
         {:ok, prices} <- membership_price_ids(),
         {:ok, promotion} <- resolve_promotion(coupon_code),
         {:ok, details} <- pricing_details(customer_id, prices, promotion) do
      {:ok, generate_pricing_info(details)}
    end
  end

  defp pending_invitation(invitation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from i in Invitation,
        where: i.id == ^invitation_id,
        where: i.status == "pending",
        where: i.expires_at > ^now

    case Repo.one(query) do
      nil -> {:error, :not_found}
      invitation -> {:ok, invitation}
    end
  end

  # ALE-162: no user_profiles row exists at pricing time. Reuse a previously
  # attached customer if present (lazily created by a prior pricing call);
  # otherwise create one and persist it on the invitation so acceptance can
  # reuse it. The customer is named from the invitation's first/last name if
  # available, emailed from the invitation email, and carries `invited_by`
  # metadata from the invitation's creator.
  defp resolve_customer_id(%Invitation{stripe_customer_id: id})
       when is_binary(id) and id != "" do
    {:ok, id}
  end

  defp resolve_customer_id(%Invitation{} = invitation) do
    name =
      [invitation.first_name, invitation.last_name]
      |> Enum.filter(&(&1 not in [nil, ""]))
      |> Enum.join(" ")

    body = %{
      "name" => name,
      "email" => invitation.email,
      "metadata[invited_by]" => invitation.created_by || invitation.user_id
    }

    idempotency_key = "invitation-pricing:#{invitation.id}:customer"

    case Operations.post_customers(body, idempotency_key: idempotency_key) do
      {:ok, %{"id" => customer_id}} when is_binary(customer_id) ->
        case Repository.attach_stripe_customer_id(invitation.id, customer_id) do
          {:ok, _invitation} -> {:ok, customer_id}
          {:error, reason} -> {:error, {:stripe_customer_persist, reason}}
        end

      {:ok, body} ->
        {:error, {:stripe_customer_missing_id, body}}

      {:error, reason} ->
        {:error, {:stripe, reason}}
    end
  end

  defp membership_price_ids do
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

  defp resolve_promotion(nil), do: {:ok, %{code: nil, promotion_code_id: nil, coupon: nil}}
  defp resolve_promotion(""), do: {:ok, %{code: nil, promotion_code_id: nil, coupon: nil}}

  defp resolve_promotion(coupon_code) when is_binary(coupon_code) do
    trimmed = String.trim(coupon_code)

    if trimmed == "" do
      resolve_promotion(nil)
    else
      case Operations.get_promotion_codes(%{}, active: true, code: trimmed, limit: 1) do
        {:ok, %{"data" => [%{"id" => id, "promotion" => %{"coupon" => coupon_id}} | _]}}
        when is_binary(id) and is_binary(coupon_id) ->
          if migration_code?(trimmed) do
            {:ok, %{code: trimmed, promotion_code_id: nil, coupon: %{migration?: true}}}
          else
            with {:ok, coupon} <- retrieve_coupon(coupon_id),
                 :ok <- validate_coupon(coupon) do
              {:ok, %{code: trimmed, promotion_code_id: id, coupon: coupon}}
            end
          end

        {:ok, %{"data" => []}} ->
          {:error, :invalid_promotion_code}

        {:error, reason} ->
          {:error, {:stripe, reason}}

        _ ->
          {:error, :invalid_promotion_code_response}
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

  defp pricing_details(customer_id, prices, promotion) do
    next_month = next_month_anchor()
    next_january = next_january_anchor()

    calls = [
      monthly_initial: fn ->
        preview_invoice(
          customer_id,
          prices.monthly.id,
          :billing_cycle_anchor,
          next_month,
          promotion_for_preview(promotion, prices.monthly, :initial)
        )
      end,
      annual_initial: fn ->
        preview_invoice(
          customer_id,
          prices.annual.id,
          :billing_cycle_anchor,
          next_january,
          promotion_for_preview(promotion, prices.annual, :initial)
        )
      end,
      monthly_recurring: fn ->
        preview_invoice(
          customer_id,
          prices.monthly.id,
          :start_date,
          next_month,
          promotion_for_preview(promotion, prices.monthly, :recurring)
        )
      end,
      annual_recurring: fn ->
        preview_invoice(
          customer_id,
          prices.annual.id,
          :start_date,
          next_january,
          promotion_for_preview(promotion, prices.annual, :recurring)
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
         discount_percentage: discount_percentage,
         coupon: promotion.code,
         discounted_monthly_fee:
           if(monthly_discount > 0, do: amount(next_month_invoice, "amount_due"), else: 0),
         discounted_annual_fee:
           if(annual_discount > 0, do: amount(next_january_invoice, "amount_due"), else: 0),
         prorated_annual_price: prorated_annual_price,
         prorated_monthly_price: prorated_monthly_price,
         coupon_details: promotion.coupon
       }}
    end
  end

  defp preview_invoice(customer_id, price_id, date_key, unix_anchor, promotion) do
    form =
      %{
        "customer" => customer_id,
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

  defp maybe_add_discount(form, %{promotion_code_id: nil}), do: form

  defp maybe_add_discount(form, %{promotion_code_id: promotion_code_id}),
    do: Map.put(form, "discounts[0][promotion_code]", promotion_code_id)

  defp promotion_for_preview(%{coupon: %{"duration" => "once"}} = promotion, _price, _phase),
    do: %{promotion | promotion_code_id: nil}

  defp promotion_for_preview(
         %{coupon: %{"applies_to" => %{"products" => products}}} = promotion,
         %{product: product},
         _phase
       )
       when is_list(products) do
    if product in products, do: promotion, else: %{promotion | promotion_code_id: nil}
  end

  defp promotion_for_preview(promotion, _price, _phase), do: promotion

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
    |> Map.put(:discounted_monthly_fee, 0)
    |> Map.put(:discounted_annual_fee, 0)
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

  defp maybe_put_money(map, _key, amount) when amount in [nil, 0], do: map
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
