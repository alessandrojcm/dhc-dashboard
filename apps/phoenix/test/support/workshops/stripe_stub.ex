defmodule Dhc.Workshops.StripeStub do
  @moduledoc """
  A configurable `Dhc.Workshops.StripeAdapter` for Workshop payment-command
  tests.

  Configuration lives in the application environment, so a command running on
  another process (a real-connection concurrency task, an Oban job) sees the
  same Stripe as the test. Every callback answers from a default unless the
  test replaced it with `put/2`:

    * `:payment_intents` / `:checkout_sessions` / `:refunds` — maps of
      provider id to the object `retrieve_*` returns.
    * `:create_payment_intent`, `:create_checkout_session`, `:create_refund`,
      `:retrieve_refund` — one-arity functions replacing the default answer;
      use them to pause a call or fail it.

  Created objects take their id from the idempotency key, so a replayed
  create answers with the same id, as Stripe does.
  """

  @behaviour Dhc.Workshops.StripeAdapter

  @env :workshop_stripe_stub

  @doc "Selects this stub as the Workshop Stripe adapter; returns a restore function."
  def install do
    previous = Application.get_env(:dhc, :workshop_stripe_adapter)
    Application.put_env(:dhc, :workshop_stripe_adapter, __MODULE__)
    Application.put_env(:dhc, @env, %{})

    fn ->
      Application.put_env(:dhc, :workshop_stripe_adapter, previous)
      Application.delete_env(:dhc, @env)
    end
  end

  @doc "Replaces one configuration key."
  def put(key, value), do: Application.put_env(:dhc, @env, Map.put(config(), key, value))

  @doc "Adds one provider object to a `retrieve_*` map."
  def put_object(kind, %{"id" => id} = object)
      when kind in [:payment_intents, :checkout_sessions, :refunds] do
    put(kind, Map.put(Map.get(config(), kind, %{}), id, object))
  end

  @doc "A succeeded member PaymentIntent for `workshop_id` and `user_id`."
  def member_payment_intent(id, workshop_id, user_id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "client_secret" => "#{id}_secret",
        "amount" => 1800,
        "currency" => "eur",
        "status" => "succeeded",
        "metadata" => %{
          "type" => "workshop_registration",
          "actor_type" => "member",
          "workshop_id" => workshop_id,
          "user_id" => user_id
        }
      },
      overrides
    )
  end

  @doc "A paid external Checkout Session for `workshop_id` and `payment_attempt_id`."
  def checkout_session(id, workshop_id, payment_attempt_id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "client_secret" => "#{id}_secret",
        "status" => "complete",
        "payment_status" => "paid",
        "amount_total" => 2400,
        "currency" => "eur",
        "payment_intent" => "pi_for_#{id}",
        "metadata" => %{
          "type" => "workshop_registration",
          "actor_type" => "external",
          "workshop_id" => workshop_id,
          "payment_attempt_id" => payment_attempt_id
        },
        "customer_details" => %{
          "email" => "guest-#{id}@example.com",
          "name" => "Grace Hopper",
          "phone" => "+353123456"
        }
      },
      overrides
    )
  end

  @impl true
  def create_payment_intent(params) do
    override(:create_payment_intent, params, fn ->
      id = "pi_" <> suffix(params.idempotency_key)

      {:ok,
       %{
         "id" => id,
         "client_secret" => "#{id}_secret",
         "amount" => params.amount,
         "currency" => params.currency,
         "status" => "requires_payment_method",
         "metadata" => %{}
       }}
    end)
  end

  @impl true
  def retrieve_payment_intent(id), do: lookup(:payment_intents, id)

  @impl true
  def create_checkout_session(params) do
    override(:create_checkout_session, params, fn ->
      id = "cs_" <> suffix(params.idempotency_key)
      {:ok, %{"id" => id, "client_secret" => "#{id}_secret", "url" => nil}}
    end)
  end

  @impl true
  def retrieve_checkout_session(id), do: lookup(:checkout_sessions, id)

  @impl true
  def update_payment_intent(_id, _params), do: :ok

  @impl true
  def create_refund(params) do
    override(:create_refund, params, fn ->
      {:ok, %{"id" => "re_" <> suffix(params.idempotency_key), "status" => "pending"}}
    end)
  end

  @impl true
  def retrieve_refund(id) do
    override(:retrieve_refund, id, fn ->
      case Map.fetch(Map.get(config(), :refunds, %{}), id) do
        {:ok, object} -> {:ok, object}
        :error -> {:ok, %{"id" => id, "status" => "succeeded"}}
      end
    end)
  end

  defp lookup(kind, id) do
    case Map.fetch(Map.get(config(), kind, %{}), id) do
      {:ok, object} -> {:ok, object}
      :error -> {:error, {:stripe_api, 404, "No such object: #{id}"}}
    end
  end

  defp override(key, arg, default) do
    case Map.get(config(), key) do
      fun when is_function(fun, 1) -> fun.(arg)
      nil -> default.()
    end
  end

  defp suffix(idempotency_key), do: idempotency_key |> String.split(":") |> List.last()

  defp config, do: Application.get_env(:dhc, @env, %{})
end
