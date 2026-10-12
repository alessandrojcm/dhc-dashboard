defmodule Dhc.BeginnersWorkshops.WorkshopPolicyPaymentWindowTest do
  @moduledoc """
  ALE-400: `WorkshopPolicy.payment_window_end/3`, the one Payment Window
  (`CONTEXT.md`). The workshop: Saturday 14 November 2026 at 18:30 Dublin
  (GMT), Payment Cutoff Wednesday 11 November 18:30 UTC.
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, WorkshopPolicy}

  @cutoff ~U[2026-11-11 18:30:00.000000Z]
  @starts ~U[2026-11-14 18:30:00Z]

  @workshop %BeginnersWorkshop{
    date: ~D[2026-11-14],
    start_time: ~T[18:30:00],
    payment_cutoff: @cutoff
  }

  test "a Batch Intake's window is its Batch's" do
    batch_end = ~U[2026-10-27 23:59:59.999999Z]

    assert WorkshopPolicy.payment_window_end(@workshop, batch_end, ~U[2026-10-20 10:00:00Z]) ==
             batch_end
  end

  test "a Fast-track contacted before the cutoff ends at the cutoff" do
    assert WorkshopPolicy.payment_window_end(@workshop, nil, ~U[2026-11-11 18:29:59Z]) ==
             @cutoff
  end

  test "a Fast-track contacted at or after the cutoff ends at the workshop start" do
    for contacted_at <- [@cutoff, ~U[2026-11-12 12:00:00Z]] do
      assert DateTime.compare(
               WorkshopPolicy.payment_window_end(@workshop, nil, contacted_at),
               @starts
             ) == :eq
    end
  end
end
