defmodule DhcWeb.BeginnersWorkshopRefundsController do
  @moduledoc """
  The `beginnersWorkshopRefunds` slice (ALE-382): the follow-ups to a failed
  Intake refund on the workshop console's Needs attention list — Retry (a
  new Stripe refund), Record manual refund and (ALE-389, a Carried Fee's
  refund only) Forfeit. None emails the person.
  The router gates both on `beginners.workshops.manage`; the boundary
  authorizes the actor again before any read.
  """
  use DhcWeb, :controller

  action_fallback DhcWeb.BeginnersWorkshopsHTTP

  alias DhcWeb.BeginnersWorkshopsHTTP

  @doc "POST /beginners-workshops/{id}/refunds/{refundId}/retry"
  def retry(conn, %{"id" => id, "refundId" => refund_id}),
    do: command(conn, {:retry_refund, id, refund_id})

  @doc "POST /beginners-workshops/{id}/refunds/{refundId}/manual"
  def record_manual(conn, %{"id" => id, "refundId" => refund_id} = params),
    do: command(conn, {:record_manual_refund, id, refund_id, Map.take(params, ["note"])})

  @doc "POST /beginners-workshops/{id}/refunds/{refundId}/forfeit"
  def forfeit(conn, %{"id" => id, "refundId" => refund_id}),
    do: BeginnersWorkshopsHTTP.command(conn, {:forfeit_carried_fee, id, refund_id}, :forfeited)

  defp command(conn, command),
    do: BeginnersWorkshopsHTTP.command(conn, command, :refund, :created)
end
