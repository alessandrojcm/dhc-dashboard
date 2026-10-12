defmodule DhcWeb.BeginnersWorkshopCarriedFeesController do
  @moduledoc """
  The `beginnersWorkshopCarriedFees` slice: the Waitlist tab's Carried Fees.

    * `index` (ALE-388) — the Carried Fee status of the people a Waitlist
      page lists. `Dhc.Waitlist` (and its web slice) never reads Beginners'
      Workshops, so the dashboard asks here. Gated on
      `beginners.waitlist.manage`, the Waitlist view's own capability.
    * (ALE-389) one person's Carried Fee (`show`), and the commands on it —
      Refund Carried Fee, link an imported fee to its Stripe payment, and
      the follow-ups to its failed refund (Retry, Record manual refund,
      Forfeit). Money, so the router gates them on
      `beginners.workshops.manage`; the boundary authorizes the actor again
      before any read. None of the follow-ups emails the person.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias Dhc.BeginnersWorkshops
  alias DhcWeb.BeginnersWorkshopsHTTP

  @max_ids 100

  @doc "GET /beginners-workshops/carried-fees?waitlistIds=a,b"
  def index(conn, params) do
    with {:ok, ids} <- waitlist_ids(Map.get(params, "waitlistIds")) do
      render(conn, :index, carried_fees: BeginnersWorkshops.carried_fees(ids))
    end
  end

  @doc "GET /beginners-workshops/people/{waitlistId}/carried-fee"
  def show(conn, %{"waitlistId" => waitlist_id}) do
    case BeginnersWorkshops.carried_fee(waitlist_id) do
      {:error, :no_carried_fee} -> {:error, :carried_fee_not_found}
      result -> BeginnersWorkshopsHTTP.respond(result, conn, :show)
    end
  end

  @doc "POST /beginners-workshops/people/{waitlistId}/carried-fee/refund"
  def refund(conn, %{"waitlistId" => waitlist_id} = params),
    do:
      command(
        conn,
        {:refund_carried_fee, waitlist_id, Map.take(params, ["note"])},
        :refunded
      )

  @doc "POST /beginners-workshops/people/{waitlistId}/carried-fee/link-payment"
  def link_payment(conn, %{"waitlistId" => waitlist_id} = params) do
    attrs = %{"payment_intent_id" => Map.get(params, "paymentIntentId")}
    command(conn, {:link_carried_fee_payment, waitlist_id, attrs}, :linked)
  end

  @doc "POST /beginners-workshops/people/{waitlistId}/carried-fee/refunds/{refundId}/retry"
  def retry_refund(conn, %{"waitlistId" => waitlist_id, "refundId" => refund_id}),
    do: command(conn, {:retry_refund, {:person, waitlist_id}, refund_id}, :refund, :created)

  @doc "POST /beginners-workshops/people/{waitlistId}/carried-fee/refunds/{refundId}/manual"
  def record_manual_refund(
        conn,
        %{"waitlistId" => waitlist_id, "refundId" => refund_id} = params
      ),
      do:
        command(
          conn,
          {:record_manual_refund, {:person, waitlist_id}, refund_id, Map.take(params, ["note"])},
          :refund,
          :created
        )

  @doc "POST /beginners-workshops/people/{waitlistId}/carried-fee/refunds/{refundId}/forfeit"
  def forfeit(conn, %{"waitlistId" => waitlist_id, "refundId" => refund_id}),
    do: command(conn, {:forfeit_carried_fee, {:person, waitlist_id}, refund_id}, :forfeited)

  defp command(conn, command, template, status \\ :ok),
    do: BeginnersWorkshopsHTTP.command(conn, command, template, status)

  defp waitlist_ids(value) when is_binary(value) do
    ids = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    casted = Enum.map(ids, &Ecto.UUID.cast/1)

    if length(ids) <= @max_ids and Enum.all?(casted, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(casted, fn {:ok, id} -> id end)},
      else: {:error, :invalid_ids}
  end

  defp waitlist_ids(_missing), do: {:error, :invalid_ids}
end
