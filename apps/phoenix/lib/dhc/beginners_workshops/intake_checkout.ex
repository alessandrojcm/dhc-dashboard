defmodule Dhc.BeginnersWorkshops.IntakeCheckout do
  @moduledoc """
  The Stripe-facing half of Intake payment (ALE-381; ALE-374 "Checkout
  Session"). Internal to the boundary: only `Dhc.BeginnersWorkshops.Commands`
  calls it, and always **between transactions** — nothing here touches the
  database.

  A Checkout Session is hosted, payment mode, quantity 1, priced in `eur`
  from the fee frozen on the payment row, with `payment_method_types` listed
  explicitly (immediate methods only: card — which carries Apple Pay and
  Google Pay — Revolut Pay and Link), `customer_email` prefilled and no
  Stripe Customer. `success_url` and `cancel_url` return to the person's own
  Intake link. Metadata carries the payment row id, but the row is always
  found by session id.

  Every parameter is derived from the payment row, so a retried create with
  the idempotency key `beginners-intake-payment:<row id>` replays the session
  Stripe already created instead of failing on changed parameters.

  Stripe requires a session's `expires_at` to be at least 30 minutes after
  it creates the session. The Seat Hold runs 30 minutes from the moment it
  is taken (`IntakePayment.expires_at`); the session is given one more
  minute (`@expiry_grace_seconds`) so the request's own latency never makes
  Stripe refuse it. The reaper expires the session as soon as the hold runs
  out, so the grace never extends a hold.
  """

  alias Dhc.BeginnersWorkshops.{IntakeLink, IntakePayment}
  alias Dhc.BeginnersWorkshops.IntakeEmails.Values
  alias Dhc.Stripe.{Failure, Operations}

  @metadata_type "beginners_intake_payment"
  @expiry_grace_seconds 60
  @payment_method_types ~w(card revolut_pay link)

  @typedoc """
  A Stripe failure: `:retryable` (try again later — the hold stays) or
  `:rejected` (Stripe refused the request itself, so no session exists).
  """
  @type failure :: :retryable | :rejected

  @typedoc "What a Checkout Session says about the payment."
  @type outcome ::
          {:complete,
           %{
             amount: integer() | nil,
             currency: String.t() | nil,
             payment_intent: String.t() | nil
           }}
          | :expired
          | :open
          | :unpaid

  @doc "The idempotency key of a payment row's Checkout Session."
  @spec idempotency_key(IntakePayment.t()) :: String.t()
  def idempotency_key(%IntakePayment{id: id}), do: "beginners-intake-payment:#{id}"

  @doc """
  Creates (or, for a retried key, replays) the Checkout Session of an open
  payment row. `person` carries the Intake link `token`, the person's
  `email` and the workshop `date`.
  """
  @spec create(IntakePayment.t(), %{token: String.t(), email: String.t(), date: Date.t()}) ::
          {:ok, %{id: String.t(), url: String.t() | nil}} | {:error, failure()}
  def create(%IntakePayment{} = row, %{token: token, email: email, date: date}) do
    link = IntakeLink.url(token)

    body = %{
      "mode" => "payment",
      "line_items[0][quantity]" => 1,
      "line_items[0][price_data][currency]" => row.currency,
      "line_items[0][price_data][unit_amount]" => row.amount_cents,
      "line_items[0][price_data][product_data][name]" =>
        "Beginners' Workshop – #{Values.date(date)}",
      "customer_email" => email,
      "expires_at" =>
        row.expires_at |> DateTime.add(@expiry_grace_seconds, :second) |> DateTime.to_unix(),
      "success_url" => link <> "?session_id={CHECKOUT_SESSION_ID}",
      "cancel_url" => link,
      "metadata[type]" => @metadata_type,
      "metadata[payment_id]" => row.id,
      "payment_intent_data[metadata][type]" => @metadata_type,
      "payment_intent_data[metadata][payment_id]" => row.id
    }

    body =
      @payment_method_types
      |> Enum.with_index()
      |> Enum.reduce(body, fn {type, index}, acc ->
        Map.put(acc, "payment_method_types[#{index}]", type)
      end)

    case Operations.post_checkout_sessions(body, idempotency_key: idempotency_key(row)) do
      {:ok, %{"id" => id} = session} when is_binary(id) -> {:ok, %{id: id, url: session["url"]}}
      {:ok, _unexpected} -> {:error, :retryable}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @doc "Retrieves a Checkout Session."
  @spec retrieve(String.t()) :: {:ok, map()} | {:error, failure()}
  def retrieve(session_id) when is_binary(session_id) do
    case Operations.get_checkout_sessions_session(session_id, %{}) do
      {:ok, %{} = session} -> {:ok, session}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @doc """
  Asks Stripe to expire a Checkout Session. Stripe refuses when the session
  is no longer open (it completed or already expired); the caller then
  retrieves it to learn which.
  """
  @spec expire(String.t()) :: {:ok, map()} | {:error, failure()}
  def expire(session_id) when is_binary(session_id) do
    case Operations.post_checkout_sessions_session_expire(session_id, %{}) do
      {:ok, %{} = session} -> {:ok, session}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @doc "Whether a Checkout Session object was created for an Intake payment."
  @spec ours?(map()) :: boolean()
  def ours?(%{"metadata" => %{"type" => @metadata_type}}), do: true
  def ours?(_session), do: false

  @doc "What a Checkout Session object says about the payment."
  @spec outcome(map()) :: outcome()
  def outcome(%{"status" => "complete", "payment_status" => "paid"} = session) do
    {:complete,
     %{
       amount: session["amount_total"],
       currency: session["currency"],
       payment_intent: payment_intent_id(session["payment_intent"])
     }}
  end

  def outcome(%{"status" => "complete"}), do: :unpaid
  def outcome(%{"status" => "expired"}), do: :expired
  def outcome(_session), do: :open

  defp payment_intent_id(id) when is_binary(id), do: id
  defp payment_intent_id(%{"id" => id}) when is_binary(id), do: id
  defp payment_intent_id(_other), do: nil

  defp failure(reason), do: if(Failure.retryable?(reason), do: :retryable, else: :rejected)
end
