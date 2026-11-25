defmodule Dhc.BeginnersWorkshops.WorkshopPolicyReOfferTest do
  @moduledoc """
  The Re-offer exception to the Payment Cutoff (`CONTEXT.md`, **Re-offer**):
  `WorkshopPolicy.late_re_offer?/2`, `intake_payment_open?/3` and
  `intake_payment_closes_at/2`. The workshop: Saturday 14 November 2026 at
  18:30 Dublin (GMT), Payment Cutoff Wednesday 11 November 18:30 UTC.
  """

  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, WorkshopPolicy}

  @cutoff ~U[2026-11-11 18:30:00.000000Z]
  @starts ~U[2026-11-14 18:30:00Z]

  @workshop %BeginnersWorkshop{
    status: "scheduled",
    date: ~D[2026-11-14],
    start_time: ~T[18:30:00],
    payment_cutoff: @cutoff
  }

  defp intake(origin, contacted_at), do: %{origin: origin, contacted_at: contacted_at}
  defp reading(now), do: %{now: now}

  test "only a Re-offer contacted at or after the current cutoff is late" do
    assert WorkshopPolicy.late_re_offer?(@workshop, intake("re_offer", @cutoff))
    assert WorkshopPolicy.late_re_offer?(@workshop, intake("re_offer", ~U[2026-11-12 09:00:00Z]))
    refute WorkshopPolicy.late_re_offer?(@workshop, intake("re_offer", ~U[2026-11-11 18:29:59Z]))
    refute WorkshopPolicy.late_re_offer?(@workshop, intake("fast_track", @cutoff))
    refute WorkshopPolicy.late_re_offer?(@workshop, intake("batch", @cutoff))
  end

  test "a reschedule that moves the cutoff past the Re-offer makes it ordinary" do
    late = intake("re_offer", ~U[2026-11-12 09:00:00Z])
    moved = %{@workshop | payment_cutoff: ~U[2026-12-02 18:30:00Z]}

    refute WorkshopPolicy.late_re_offer?(moved, late)
    assert WorkshopPolicy.intake_payment_closes_at(moved, late) == moved.payment_cutoff
  end

  test "a late Re-offer may start payment until the start; everyone else until the cutoff" do
    late = intake("re_offer", ~U[2026-11-12 09:00:00Z])
    other = intake("batch", ~U[2026-10-20 10:00:00Z])
    after_cutoff = reading(~U[2026-11-12 12:00:00Z])

    assert WorkshopPolicy.intake_payment_open?(
             @workshop,
             other,
             reading(~U[2026-11-01 12:00:00Z])
           )

    refute WorkshopPolicy.intake_payment_open?(@workshop, other, after_cutoff)
    assert WorkshopPolicy.intake_payment_open?(@workshop, late, after_cutoff)
    refute WorkshopPolicy.intake_payment_open?(@workshop, late, reading(@starts))

    refute WorkshopPolicy.intake_payment_open?(
             %{@workshop | status: "cancelled"},
             late,
             after_cutoff
           )
  end

  test "the page's payment deadline is the start for a late Re-offer, else the cutoff" do
    late = intake("re_offer", ~U[2026-11-12 09:00:00Z])

    assert DateTime.compare(WorkshopPolicy.intake_payment_closes_at(@workshop, late), @starts) ==
             :eq

    assert WorkshopPolicy.intake_payment_closes_at(@workshop, intake("batch", @cutoff)) == @cutoff
  end

  test "a late Re-offer's Payment Window ends at the start" do
    assert DateTime.compare(
             WorkshopPolicy.payment_window_end(@workshop, nil, ~U[2026-11-12 09:00:00Z]),
             @starts
           ) == :eq
  end
end
