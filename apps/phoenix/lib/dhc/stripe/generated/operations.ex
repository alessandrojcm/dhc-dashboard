defmodule Dhc.Stripe.Operations do
  @moduledoc """
  Provides API endpoints related to operations
  """

  @default_client Dhc.Stripe.Client

  @doc """
  Cancel a subscription

  <p>Cancels a customer’s subscription immediately. The customer won’t be charged again for the subscription. After it’s canceled, the subscription is largely immutable. You can still update its <a href="/metadata">metadata</a> and <code>cancellation_details</code>.</p>

  <p>Any pending invoice items that you’ve created are still charged at the end of the period, unless manually <a href="/api/invoiceitems/delete">deleted</a>. If you’ve set the subscription to cancel at the end of the period, any pending prorations are also left in place and collected at the end of the period. But if the subscription is set to cancel immediately, pending prorations are removed if <code>invoice_now</code> and <code>prorate</code> are both set to false.</p>

  <p>By default, upon subscription cancellation, Stripe stops automatic collection of all finalized invoices for the customer. This is intended to prevent unexpected payment attempts after the customer has canceled a subscription. However, you can resume automatic collection of the invoices manually after subscription cancellation to have us proceed. Or, you could check for unpaid invoices before allowing the customer to cancel the subscription at all.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec delete_subscriptions_subscription_exposed_id(
          subscription_exposed_id :: String.t(),
          body :: map,
          opts :: keyword
        ) :: {:ok, Dhc.Stripe.Subscription.t()} | {:error, Dhc.Stripe.Error.t()}
  def delete_subscriptions_subscription_exposed_id(subscription_exposed_id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [subscription_exposed_id: subscription_exposed_id, body: body],
      call: {Dhc.Stripe.Operations, :delete_subscriptions_subscription_exposed_id},
      url: "/v1/subscriptions/#{subscription_exposed_id}",
      body: body,
      method: :delete,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Subscription, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Retrieve a Checkout Session

  <p>Retrieves a Checkout Session object.</p>

  ## Options

    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_checkout_sessions_session(session :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.CheckoutSession.t()} | {:error, Dhc.Stripe.Error.t()}
  def get_checkout_sessions_session(session, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:expand])

    client.request(%{
      args: [session: session, body: body],
      call: {Dhc.Stripe.Operations, :get_checkout_sessions_session},
      url: "/v1/checkout/sessions/#{session}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.CheckoutSession, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Retrieve a coupon

  <p>Retrieves the coupon with the given ID.</p>

  ## Options

    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_coupons_coupon(coupon :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Coupon.t()} | {:error, Dhc.Stripe.Error.t()}
  def get_coupons_coupon(coupon, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:expand])

    client.request(%{
      args: [coupon: coupon, body: body],
      call: {Dhc.Stripe.Operations, :get_coupons_coupon},
      url: "/v1/coupons/#{coupon}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Coupon, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @type get_customers_200_json_resp :: %{
          data: [Dhc.Stripe.Customer.t()],
          has_more: boolean,
          object: String.t(),
          url: String.t()
        }

  @doc """
  List all customers

  <p>Returns a list of your customers. The customers are returned sorted by creation date, with the most recent customers appearing first.</p>

  ## Options

    * `created`: Only return customers that were created during the given date interval.
    * `email`: A case-sensitive filter on the list based on the customer's `email` field. The value must be a string.
    * `ending_before`: A cursor for use in pagination. `ending_before` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, starting with `obj_bar`, your subsequent call can include `ending_before=obj_bar` in order to fetch the previous page of the list.
    * `expand`: Specifies which fields in the response should be expanded.
    * `limit`: A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.
    * `starting_after`: A cursor for use in pagination. `starting_after` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, ending with `obj_foo`, your subsequent call can include `starting_after=obj_foo` in order to fetch the next page of the list.
    * `test_clock`: Provides a list of customers that are associated with the specified test clock. The response will not include customers with test clocks if this parameter is not set.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_customers(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Operations.get_customers_200_json_resp()}
          | {:error, Dhc.Stripe.Error.t()}
  def get_customers(body, opts \\ []) do
    client = opts[:client] || @default_client

    query =
      Keyword.take(opts, [
        :created,
        :email,
        :ending_before,
        :expand,
        :limit,
        :starting_after,
        :test_clock
      ])

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :get_customers},
      url: "/v1/customers",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [
        {200, {Dhc.Stripe.Operations, :get_customers_200_json_resp}},
        default: {Dhc.Stripe.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Retrieve a customer

  <p>Retrieves a Customer object.</p>

  ## Options

    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_customers_customer(customer :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t()}
          | {:error, Dhc.Stripe.Error.t()}
  def get_customers_customer(customer, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:expand])

    client.request(%{
      args: [customer: customer, body: body],
      call: {Dhc.Stripe.Operations, :get_customers_customer},
      url: "/v1/customers/#{customer}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [
        {200, {:union, [{Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]}},
        default: {Dhc.Stripe.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Retrieve a PaymentIntent

  <p>Retrieves the details of a PaymentIntent that has previously been created. </p>

  <p>You can retrieve a PaymentIntent client-side using a publishable key when the <code>client_secret</code> is in the query string. </p>

  <p>If you retrieve a PaymentIntent with a publishable key, it only returns a subset of properties. Refer to the <a href="#payment_intent_object">payment intent</a> object reference for more details.</p>

  ## Options

    * `client_secret`: The client secret of the PaymentIntent. We require it if you use a publishable key to retrieve the source.
    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_payment_intents_intent(intent :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.PaymentIntent.t()} | {:error, Dhc.Stripe.Error.t()}
  def get_payment_intents_intent(intent, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:client_secret, :expand])

    client.request(%{
      args: [intent: intent, body: body],
      call: {Dhc.Stripe.Operations, :get_payment_intents_intent},
      url: "/v1/payment_intents/#{intent}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.PaymentIntent, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @type get_prices_200_json_resp :: %{
          data: [Dhc.Stripe.Price.t()],
          has_more: boolean,
          object: String.t(),
          url: String.t()
        }

  @doc """
  List all prices

  <p>Returns a list of your active prices, excluding <a href="/docs/products-prices/pricing-models#inline-pricing">inline prices</a>. For the list of inactive prices, set <code>active</code> to false.</p>

  ## Options

    * `active`: Only return prices that are active or inactive (e.g., pass `false` to list all inactive prices).
    * `created`: A filter on the list, based on the object `created` field. The value can be a string with an integer Unix timestamp, or it can be a dictionary with a number of different query options.
    * `currency`: Only return prices for the given currency.
    * `ending_before`: A cursor for use in pagination. `ending_before` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, starting with `obj_bar`, your subsequent call can include `ending_before=obj_bar` in order to fetch the previous page of the list.
    * `expand`: Specifies which fields in the response should be expanded.
    * `limit`: A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.
    * `lookup_keys`: Only return the price with these lookup_keys, if any exist. You can specify up to 10 lookup_keys.
    * `product`: Only return prices for the given product.
    * `recurring`: Only return prices with these recurring fields.
    * `starting_after`: A cursor for use in pagination. `starting_after` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, ending with `obj_foo`, your subsequent call can include `starting_after=obj_foo` in order to fetch the next page of the list.
    * `type`: Only return prices of type `recurring` or `one_time`.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_prices(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Operations.get_prices_200_json_resp()} | {:error, Dhc.Stripe.Error.t()}
  def get_prices(body, opts \\ []) do
    client = opts[:client] || @default_client

    query =
      Keyword.take(opts, [
        :active,
        :created,
        :currency,
        :ending_before,
        :expand,
        :limit,
        :lookup_keys,
        :product,
        :recurring,
        :starting_after,
        :type
      ])

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :get_prices},
      url: "/v1/prices",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [
        {200, {Dhc.Stripe.Operations, :get_prices_200_json_resp}},
        default: {Dhc.Stripe.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Retrieve a price

  <p>Retrieves the price with the given ID.</p>

  ## Options

    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_prices_price(price :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Price.t()} | {:error, Dhc.Stripe.Error.t()}
  def get_prices_price(price, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:expand])

    client.request(%{
      args: [price: price, body: body],
      call: {Dhc.Stripe.Operations, :get_prices_price},
      url: "/v1/prices/#{price}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Price, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @type get_promotion_codes_200_json_resp :: %{
          data: [Dhc.Stripe.PromotionCode.t()],
          has_more: boolean,
          object: String.t(),
          url: String.t()
        }

  @doc """
  List all promotion codes

  <p>Returns a list of your promotion codes.</p>

  ## Options

    * `active`: Filter promotion codes by whether they are active.
    * `code`: Only return promotion codes that have this case-insensitive code.
    * `coupon`: Only return promotion codes for this coupon.
    * `created`: A filter on the list, based on the object `created` field. The value can be a string with an integer Unix timestamp, or it can be a dictionary with a number of different query options.
    * `customer`: Only return promotion codes that are restricted to this customer.
    * `customer_account`: Only return promotion codes that are restricted to this account representing the customer.
    * `ending_before`: A cursor for use in pagination. `ending_before` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, starting with `obj_bar`, your subsequent call can include `ending_before=obj_bar` in order to fetch the previous page of the list.
    * `expand`: Specifies which fields in the response should be expanded.
    * `limit`: A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.
    * `starting_after`: A cursor for use in pagination. `starting_after` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, ending with `obj_foo`, your subsequent call can include `starting_after=obj_foo` in order to fetch the next page of the list.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_promotion_codes(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Operations.get_promotion_codes_200_json_resp()}
          | {:error, Dhc.Stripe.Error.t()}
  def get_promotion_codes(body, opts \\ []) do
    client = opts[:client] || @default_client

    query =
      Keyword.take(opts, [
        :active,
        :code,
        :coupon,
        :created,
        :customer,
        :customer_account,
        :ending_before,
        :expand,
        :limit,
        :starting_after
      ])

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :get_promotion_codes},
      url: "/v1/promotion_codes",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [
        {200, {Dhc.Stripe.Operations, :get_promotion_codes_200_json_resp}},
        default: {Dhc.Stripe.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Retrieve a refund

  <p>Retrieves the details of an existing refund.</p>

  ## Options

    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_refunds_refund(refund :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Refund.t()} | {:error, Dhc.Stripe.Error.t()}
  def get_refunds_refund(refund, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:expand])

    client.request(%{
      args: [refund: refund, body: body],
      call: {Dhc.Stripe.Operations, :get_refunds_refund},
      url: "/v1/refunds/#{refund}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Refund, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @type get_setup_intents_200_json_resp :: %{
          data: [Dhc.Stripe.SetupIntent.t()],
          has_more: boolean,
          object: String.t(),
          url: String.t()
        }

  @doc """
  List all SetupIntents

  <p>Returns a list of SetupIntents.</p>

  ## Options

    * `attach_to_self`: If present, the SetupIntent's payment method will be attached to the in-context Stripe Account.

      It can only be used for this Stripe Account’s own money movement flows like InboundTransfer and OutboundTransfers. It cannot be set to true when setting up a PaymentMethod for a Customer, and defaults to false when attaching a PaymentMethod to a Customer.
    * `created`: A filter on the list, based on the object `created` field. The value can be a string with an integer Unix timestamp, or it can be a dictionary with a number of different query options.
    * `customer`: Only return SetupIntents for the customer specified by this customer ID.
    * `customer_account`: Only return SetupIntents for the account specified by this customer ID.
    * `ending_before`: A cursor for use in pagination. `ending_before` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, starting with `obj_bar`, your subsequent call can include `ending_before=obj_bar` in order to fetch the previous page of the list.
    * `expand`: Specifies which fields in the response should be expanded.
    * `limit`: A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.
    * `payment_method`: Only return SetupIntents that associate with the specified payment method.
    * `starting_after`: A cursor for use in pagination. `starting_after` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, ending with `obj_foo`, your subsequent call can include `starting_after=obj_foo` in order to fetch the next page of the list.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_setup_intents(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Operations.get_setup_intents_200_json_resp()}
          | {:error, Dhc.Stripe.Error.t()}
  def get_setup_intents(body, opts \\ []) do
    client = opts[:client] || @default_client

    query =
      Keyword.take(opts, [
        :attach_to_self,
        :created,
        :customer,
        :customer_account,
        :ending_before,
        :expand,
        :limit,
        :payment_method,
        :starting_after
      ])

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :get_setup_intents},
      url: "/v1/setup_intents",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [
        {200, {Dhc.Stripe.Operations, :get_setup_intents_200_json_resp}},
        default: {Dhc.Stripe.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Retrieve a SetupIntent

  <p>Retrieves the details of a SetupIntent that has previously been created. </p>

  <p>Client-side retrieval using a publishable key is allowed when the <code>client_secret</code> is provided in the query string. </p>

  <p>When retrieved with a publishable key, only a subset of properties will be returned. Please refer to the <a href="#setup_intent_object">SetupIntent</a> object reference for more details.</p>

  ## Options

    * `client_secret`: The client secret of the SetupIntent. We require this string if you use a publishable key to retrieve the SetupIntent.
    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_setup_intents_intent(intent :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.SetupIntent.t()} | {:error, Dhc.Stripe.Error.t()}
  def get_setup_intents_intent(intent, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:client_secret, :expand])

    client.request(%{
      args: [intent: intent, body: body],
      call: {Dhc.Stripe.Operations, :get_setup_intents_intent},
      url: "/v1/setup_intents/#{intent}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.SetupIntent, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @type get_subscriptions_200_json_resp :: %{
          data: [Dhc.Stripe.Subscription.t()],
          has_more: boolean,
          object: String.t(),
          url: String.t()
        }

  @doc """
  List subscriptions

  <p>By default, returns a list of subscriptions that have not been canceled. In order to list canceled subscriptions, specify <code>status=canceled</code>.</p>

  ## Options

    * `automatic_tax`: Filter subscriptions by their automatic tax settings.
    * `collection_method`: The collection method of the subscriptions to retrieve. Either `charge_automatically` or `send_invoice`.
    * `created`: Only return subscriptions that were created during the given date interval.
    * `current_period_end`: Only return subscriptions whose minimum item current_period_end falls within the given date interval.
    * `current_period_start`: Only return subscriptions whose maximum item current_period_start falls within the given date interval.
    * `customer`: The ID of the customer whose subscriptions you're retrieving.
    * `customer_account`: The ID of the account representing the customer whose subscriptions you're retrieving.
    * `ending_before`: A cursor for use in pagination. `ending_before` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, starting with `obj_bar`, your subsequent call can include `ending_before=obj_bar` in order to fetch the previous page of the list.
    * `expand`: Specifies which fields in the response should be expanded.
    * `limit`: A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.
    * `price`: Filter for subscriptions that contain this recurring price ID.
    * `starting_after`: A cursor for use in pagination. `starting_after` is an object ID that defines your place in the list. For instance, if you make a list request and receive 100 objects, ending with `obj_foo`, your subsequent call can include `starting_after=obj_foo` in order to fetch the next page of the list.
    * `status`: The status of the subscriptions to retrieve. Passing in a value of `canceled` will return all canceled subscriptions, including those belonging to deleted customers. Pass `ended` to find subscriptions that are canceled and subscriptions that are expired due to [incomplete payment](https://docs.stripe.com/billing/subscriptions/overview#subscription-statuses). Passing in a value of `all` will return subscriptions of all statuses. If no value is supplied, all subscriptions that have not been canceled are returned.
    * `test_clock`: Filter for subscriptions that are associated with the specified test clock. The response will not include subscriptions with test clocks if this and the customer parameter is not set.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_subscriptions(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Operations.get_subscriptions_200_json_resp()}
          | {:error, Dhc.Stripe.Error.t()}
  def get_subscriptions(body, opts \\ []) do
    client = opts[:client] || @default_client

    query =
      Keyword.take(opts, [
        :automatic_tax,
        :collection_method,
        :created,
        :current_period_end,
        :current_period_start,
        :customer,
        :customer_account,
        :ending_before,
        :expand,
        :limit,
        :price,
        :starting_after,
        :status,
        :test_clock
      ])

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :get_subscriptions},
      url: "/v1/subscriptions",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [
        {200, {Dhc.Stripe.Operations, :get_subscriptions_200_json_resp}},
        default: {Dhc.Stripe.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Retrieve a subscription

  <p>Retrieves the subscription with the given ID.</p>

  ## Options

    * `expand`: Specifies which fields in the response should be expanded.

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec get_subscriptions_subscription_exposed_id(
          subscription_exposed_id :: String.t(),
          body :: map,
          opts :: keyword
        ) :: {:ok, Dhc.Stripe.Subscription.t()} | {:error, Dhc.Stripe.Error.t()}
  def get_subscriptions_subscription_exposed_id(subscription_exposed_id, body, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:expand])

    client.request(%{
      args: [subscription_exposed_id: subscription_exposed_id, body: body],
      call: {Dhc.Stripe.Operations, :get_subscriptions_subscription_exposed_id},
      url: "/v1/subscriptions/#{subscription_exposed_id}",
      body: body,
      method: :get,
      query: query,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Subscription, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a portal session

  <p>Creates a session of the customer portal.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_billing_portal_sessions(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.BillingPortalSession.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_billing_portal_sessions(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_billing_portal_sessions},
      url: "/v1/billing_portal/sessions",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.BillingPortalSession, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a Checkout Session

  <p>Creates a Checkout Session object.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_checkout_sessions(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.CheckoutSession.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_checkout_sessions(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_checkout_sessions},
      url: "/v1/checkout/sessions",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.CheckoutSession, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a credit note

  <p>Issue a credit note to adjust the amount of a finalized invoice. A credit note will first reduce the invoice’s <code>amount_remaining</code> (and <code>amount_due</code>), but not below zero.
  This amount is indicated by the credit note’s <code>pre_payment_amount</code>. The excess amount is indicated by <code>post_payment_amount</code>, and it can result in any combination of the following:</p>

  <ul>
  <li>Refunds: create a new refund (using <code>refund_amount</code>) or link existing refunds (using <code>refunds</code>).</li>
  <li>Customer balance credit: credit the customer’s balance (using <code>credit_amount</code>) which will be automatically applied to their next invoice when it’s finalized.</li>
  <li>Outside of Stripe credit: record the amount that is or will be credited outside of Stripe (using <code>out_of_band_amount</code>).</li>
  </ul>

  <p>The sum of refunds, customer balance credits, and outside of Stripe credits must equal the <code>post_payment_amount</code>.</p>

  <p>You may issue multiple credit notes for an invoice. Each credit note may increment the invoice’s <code>pre_payment_credit_notes_amount</code>,
  <code>post_payment_credit_notes_amount</code>, or both, depending on the invoice’s <code>amount_remaining</code> at the time of credit note creation.</p>

  <p>For invoices that also have refunds created through the <a href="/docs/api/refunds">Refund API</a>, the credit note API subtracts those refund amounts from the maximum creditable amount. This prevents the combined credit notes and refunds from exceeding the invoice amount. If you use both, ensure the combined total does not exceed the invoice’s paid amount.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_credit_notes(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.CreditNote.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_credit_notes(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_credit_notes},
      url: "/v1/credit_notes",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.CreditNote, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a customer

  <p>Creates a new customer object.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_customers(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Customer.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_customers(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_customers},
      url: "/v1/customers",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Customer, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a preview invoice

  <p>At any time, you can preview the upcoming invoice for a subscription or subscription schedule. This will show you all the charges that are pending, including subscription renewal charges, invoice item charges, etc. It will also show you any discounts that are applicable to the invoice.</p>

  <p>You can also preview the effects of creating or updating a subscription or subscription schedule, including a preview of any prorations that will take place. To ensure that the actual proration is calculated exactly the same as the previewed proration, you should pass the <code>subscription_details.proration_date</code> parameter when doing the actual subscription update.</p>

  <p>The recommended way to get only the prorations being previewed on the invoice is to consider line items where <code>parent.subscription_item_details.proration</code> is <code>true</code>.</p>

  <p>Note that when you are viewing an upcoming invoice, you are simply viewing a preview – the invoice has not yet been created. As such, the upcoming invoice will not show up in invoice listing calls, and you cannot use the API to pay or edit the invoice. If you want to change the amount that your customer will be billed, you can add, remove, or update pending invoice items, or update the customer’s discount.</p>

  <p>Note: Currency conversion calculations use the latest exchange rates. Exchange rates may vary between the time of the preview and the time of the actual invoice creation. <a href="https://docs.stripe.com/currencies/conversions">Learn more</a></p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_invoices_create_preview(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Invoice.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_invoices_create_preview(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_invoices_create_preview},
      url: "/v1/invoices/create_preview",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Invoice, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a PaymentIntent

  <p>Creates a PaymentIntent object.</p>

  <p>After the PaymentIntent is created, attach a payment method and <a href="/docs/api/payment_intents/confirm">confirm</a>
  to continue the payment. Learn more about <a href="/docs/payments/payment-intents">the available payment flows
  with the Payment Intents API</a>.</p>

  <p>When you use <code>confirm=true</code> during creation, it’s equivalent to creating
  and confirming the PaymentIntent in the same call. You can use any parameters
  available in the <a href="/docs/api/payment_intents/confirm">confirm API</a> when you supply
  <code>confirm=true</code>.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_payment_intents(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.PaymentIntent.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_payment_intents(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_payment_intents},
      url: "/v1/payment_intents",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.PaymentIntent, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Update a PaymentIntent

  <p>Updates properties on a PaymentIntent object without confirming.</p>

  <p>Depending on which properties you update, you might need to confirm the
  PaymentIntent again. For example, updating the <code>payment_method</code>
  always requires you to confirm the PaymentIntent again. If you prefer to
  update and confirm at the same time, we recommend updating properties through
  the <a href="/docs/api/payment_intents/confirm">confirm API</a> instead.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_payment_intents_intent(intent :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.PaymentIntent.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_payment_intents_intent(intent, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [intent: intent, body: body],
      call: {Dhc.Stripe.Operations, :post_payment_intents_intent},
      url: "/v1/payment_intents/#{intent}",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.PaymentIntent, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Confirm a PaymentIntent

  <p>Confirm that your customer intends to pay with current or provided
  payment method. Upon confirmation, the PaymentIntent will attempt to initiate
  a payment.</p>

  <p>If the selected payment method requires additional authentication steps, the
  PaymentIntent will transition to the <code>requires_action</code> status and
  suggest additional actions via <code>next_action</code>. If payment fails,
  the PaymentIntent transitions to the <code>requires_payment_method</code> status or the
  <code>canceled</code> status if the confirmation limit is reached. If
  payment succeeds, the PaymentIntent will transition to the <code>succeeded</code>
  status (or <code>requires_capture</code>, if <code>capture_method</code> is set to <code>manual</code>).</p>

  <p>If the <code>confirmation_method</code> is <code>automatic</code>, payment may be attempted
  using our <a href="/docs/stripe-js/reference#stripe-handle-card-payment">client SDKs</a>
  and the PaymentIntent’s <a href="#payment_intent_object-client_secret">client_secret</a>.
  After <code>next_action</code>s are handled by the client, no additional
  confirmation is required to complete the payment.</p>

  <p>If the <code>confirmation_method</code> is <code>manual</code>, all payment attempts must be
  initiated using a secret key.</p>

  <p>If any actions are required for the payment, the PaymentIntent will
  return to the <code>requires_confirmation</code> state
  after those actions are completed. Your server needs to then
  explicitly re-confirm the PaymentIntent to initiate the next payment
  attempt.</p>

  <p>There is a variable upper limit on how many times a PaymentIntent can be confirmed.
  After this limit is reached, any further calls to this endpoint will
  transition the PaymentIntent to the <code>canceled</code> state.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_payment_intents_intent_confirm(intent :: String.t(), body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.PaymentIntent.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_payment_intents_intent_confirm(intent, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [intent: intent, body: body],
      call: {Dhc.Stripe.Operations, :post_payment_intents_intent_confirm},
      url: "/v1/payment_intents/#{intent}/confirm",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.PaymentIntent, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a price

  <p>Creates a new <a href="https://docs.stripe.com/api/prices">Price</a> for an existing <a href="https://docs.stripe.com/api/products">Product</a>. The Price can be recurring or one-time.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_prices(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Price.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_prices(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_prices},
      url: "/v1/prices",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Price, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a refund

  <p>When you create a new refund, you must specify a Charge or a PaymentIntent object on which to create it.</p>

  <p>Creating a new refund will refund a charge that has previously been created but not yet refunded.
  Funds will be refunded to the credit or debit card that was originally charged.</p>

  <p>You can optionally refund only part of a charge.
  You can do so multiple times, until the entire charge has been refunded.</p>

  <p>Once entirely refunded, a charge can’t be refunded again.
  This method will raise an error when called on an already-refunded charge,
  or when trying to refund more money than is left on a charge.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_refunds(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Refund.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_refunds(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_refunds},
      url: "/v1/refunds",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Refund, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a SetupIntent

  <p>Creates a SetupIntent object.</p>

  <p>After you create the SetupIntent, attach a payment method and <a href="/docs/api/setup_intents/confirm">confirm</a>
  it to collect any required permissions to charge the payment method later.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_setup_intents(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.SetupIntent.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_setup_intents(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_setup_intents},
      url: "/v1/setup_intents",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.SetupIntent, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Create a subscription

  <p>Creates a new subscription on an existing customer. Each customer can have up to 500 active or scheduled subscriptions.</p>

  <p>When you create a subscription with <code>collection_method=charge_automatically</code>, the first invoice is finalized as part of the request.
  The <code>payment_behavior</code> parameter determines the exact behavior of the initial payment.</p>

  <p>To start subscriptions where the first invoice always begins in a <code>draft</code> status, use <a href="/docs/billing/subscriptions/subscription-schedules#managing">subscription schedules</a> instead.
  Schedules provide the flexibility to model more complex billing configurations that change over time.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_subscriptions(body :: map, opts :: keyword) ::
          {:ok, Dhc.Stripe.Subscription.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_subscriptions(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Dhc.Stripe.Operations, :post_subscriptions},
      url: "/v1/subscriptions",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Subscription, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Update a subscription

  <p>Updates an existing subscription to match the specified parameters.
  When changing prices or quantities, we optionally prorate the price we charge next month to make up for any price changes.
  To preview how the proration is calculated, use the <a href="/docs/api/invoices/create_preview">create preview</a> endpoint.</p>

  <p>By default, we prorate subscription changes. For example, if a customer signs up on May 1 for a <currency>100</currency> price, they’ll be billed <currency>100</currency> immediately. If on May 15 they switch to a <currency>200</currency> price, then on June 1 they’ll be billed <currency>250</currency> (<currency>200</currency> for a renewal of her subscription, plus a <currency>50</currency> prorating adjustment for half of the previous month’s <currency>100</currency> difference). Similarly, a downgrade generates a credit that is applied to the next invoice. We also prorate when you make quantity changes.</p>

  <p>Switching prices does not normally change the billing date or generate an immediate charge unless:</p>

  <ul>
  <li>The billing interval is changed (for example, from monthly to yearly).</li>
  <li>The subscription moves from free to paid.</li>
  <li>A trial starts or ends.</li>
  </ul>

  <p>In these cases, we apply a credit for the unused time on the previous price, immediately charge the customer using the new price, and reset the billing date. Learn about how <a href="/docs/billing/subscriptions/upgrade-downgrade#immediate-payment">Stripe immediately attempts payment for subscription changes</a>.</p>

  <p>If you want to charge for an upgrade immediately, pass <code>proration_behavior</code> as <code>always_invoice</code> to create prorations, automatically invoice the customer for those proration adjustments, and attempt to collect payment. If you pass <code>create_prorations</code>, the prorations are created but not automatically invoiced. If you want to bill the customer for the prorations before the subscription’s renewal date, you need to manually <a href="/docs/api/invoices/create">invoice the customer</a>.</p>

  <p>If you don’t want to prorate, set the <code>proration_behavior</code> option to <code>none</code>. With this option, the customer is billed <currency>100</currency> on May 1 and <currency>200</currency> on June 1. Similarly, if you set <code>proration_behavior</code> to <code>none</code> when switching between different billing intervals (for example, from monthly to yearly), we don’t generate any credits for the old subscription’s unused time. We still reset the billing date and bill immediately for the new subscription.</p>

  <p>Updating the quantity on a subscription many times in an hour may result in <a href="/docs/rate-limits">rate limiting</a>. If you need to bill for a frequently changing quantity, consider integrating <a href="/docs/billing/subscriptions/usage-based">usage-based billing</a> instead.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_subscriptions_subscription_exposed_id(
          subscription_exposed_id :: String.t(),
          body :: map,
          opts :: keyword
        ) :: {:ok, Dhc.Stripe.Subscription.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_subscriptions_subscription_exposed_id(subscription_exposed_id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [subscription_exposed_id: subscription_exposed_id, body: body],
      call: {Dhc.Stripe.Operations, :post_subscriptions_subscription_exposed_id},
      url: "/v1/subscriptions/#{subscription_exposed_id}",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Subscription, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Resume a subscription

  <p>Initiates resumption of a paused subscription, optionally resetting the billing cycle anchor and creating prorations. Resume is only available for subscriptions that use <code>charge_automatically</code> collection. If Stripe doesn’t generate a resumption invoice, the subscription becomes <code>active</code> immediately. When a resumption invoice is generated, Stripe finalizes it immediately. If the invoice is paid or marked uncollectible, the subscription becomes <code>active</code>. If the invoice is manually voided, the subscription stays <code>paused</code>. If there is no payment attempt within 23 hours, Stripe voids the invoice and the subscription stays <code>paused</code>. Learn more about <a href="/docs/billing/subscriptions/pause#resume-subscriptions">resuming subscriptions</a>.</p>

  ## Request Body

  **Content Types**: `application/x-www-form-urlencoded`
  """
  @spec post_subscriptions_subscription_resume(
          subscription :: String.t(),
          body :: map,
          opts :: keyword
        ) :: {:ok, Dhc.Stripe.Subscription.t()} | {:error, Dhc.Stripe.Error.t()}
  def post_subscriptions_subscription_resume(subscription, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [subscription: subscription, body: body],
      call: {Dhc.Stripe.Operations, :post_subscriptions_subscription_resume},
      url: "/v1/subscriptions/#{subscription}/resume",
      body: body,
      method: :post,
      request: [{"application/x-www-form-urlencoded", :map}],
      response: [{200, {Dhc.Stripe.Subscription, :t}}, default: {Dhc.Stripe.Error, :t}],
      opts: opts
    })
  end

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(:get_customers_200_json_resp) do
    [
      data: [{Dhc.Stripe.Customer, :t}],
      has_more: :boolean,
      object: {:const, "list"},
      url: :string
    ]
  end

  def __fields__(:get_prices_200_json_resp) do
    [data: [{Dhc.Stripe.Price, :t}], has_more: :boolean, object: {:const, "list"}, url: :string]
  end

  def __fields__(:get_promotion_codes_200_json_resp) do
    [
      data: [{Dhc.Stripe.PromotionCode, :t}],
      has_more: :boolean,
      object: {:const, "list"},
      url: :string
    ]
  end

  def __fields__(:get_setup_intents_200_json_resp) do
    [
      data: [{Dhc.Stripe.SetupIntent, :t}],
      has_more: :boolean,
      object: {:const, "list"},
      url: :string
    ]
  end

  def __fields__(:get_subscriptions_200_json_resp) do
    [
      data: [{Dhc.Stripe.Subscription, :t}],
      has_more: :boolean,
      object: {:const, "list"},
      url: :string
    ]
  end
end
