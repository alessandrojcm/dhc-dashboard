defmodule Dhc.BeginnersWorkshops.IntakePage do
  @moduledoc """
  The person's Intake page read model (ALE-381; ALE-374 "Intake link and
  Intake page"): what an Intake link shows. No lock and no actor — the link
  is the capability, and an unknown link is `{:error, :not_found}`.

  The view is closed and its `state` is the discriminator:

    * `pay` — a `contacted` Intake before the Payment Cutoff with a free seat,
      or with its own live Seat Hold (then the action continues that
      checkout instead of starting one);
    * `payment_in_progress` — the person came back from a checkout whose
      session is still open on our side, or their hold ran out and Stripe has
      not ended it yet; the page refreshes until Phoenix reports `paid`;
    * `confirm` (ALE-388) — a `contacted` Intake whose person holds a `held`
      Carried Fee, with a free seat: the action confirms the place with the
      fee instead of paying. The Payment Cutoff does not close it (only
      Attendance Finalisation does), and it carries no fee;
    * `full` — every seat is paid or held; seats may free up before the
      cutoff, so the action checks again (a Carried Fee holder keeps their
      fee and may check again until finalisation);
    * `paid`;
    * `closed` — `inactive` for an Intake that is no longer open (or whose
      workshop is no longer scheduled), `payment_closed` for a contacted
      Intake after the Payment Cutoff.

  It carries the first name, the
  workshop date, start time and venue, the fee and one action — never ids or
  Stripe objects; an `inactive` page carries none of them. Seats come from
  the same `WorkshopFacts` and `WorkshopPolicy` the boundary decides with, so
  a stale page can be out of date but never judge differently.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeLink,
    IntakePayment,
    WorkshopFacts,
    WorkshopPolicy
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @type state :: :pay | :confirm | :payment_in_progress | :full | :paid | :closed
  @type action :: :pay | :confirm | :continue_payment | :check_again | :none

  @type t :: %{
          state: state(),
          action: action(),
          closed_reason: :inactive | :payment_closed | nil,
          first_name: String.t() | nil,
          workshop: %{date: Date.t(), start_time: Time.t(), venue: String.t()} | nil,
          fee_cents: pos_integer() | nil
        }

  @doc "Every state, in display order."
  @spec states() :: [state()]
  def states, do: [:pay, :confirm, :payment_in_progress, :full, :paid, :closed]

  @doc """
  The page behind `token` at the clock's reading. Option `returned_session:`
  is the Checkout Session id the person was sent back with (the success
  return): while that session's hold is still open, the page is
  `payment_in_progress`.
  """
  @spec show(String.t(), Clock.t(), keyword()) :: {:ok, t()} | {:error, :not_found}
  def show(token, %Clock{} = clock, opts \\ []) when is_binary(token) do
    hash = IntakeLink.hash(token)

    from(i in Intake,
      join: w in BeginnersWorkshop,
      on: w.id == i.workshop_id,
      where: i.link_token_hash == ^hash,
      select: {i, w}
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      {intake, workshop} -> {:ok, view(intake, workshop, Clock.read(clock), opts)}
    end
  end

  defp view(intake, workshop, reading, opts) do
    hold = open_hold(intake)
    holder? = holder?(intake)
    context = %{hold: hold, holder?: holder?, returned: Keyword.get(opts, :returned_session)}

    case decide(intake, workshop, context, reading) do
      {:closed, :inactive} ->
        %{
          state: :closed,
          action: :none,
          closed_reason: :inactive,
          first_name: nil,
          workshop: nil,
          fee_cents: nil
        }

      {state, action, closed_reason} ->
        %{
          state: state,
          action: action,
          closed_reason: closed_reason,
          first_name: first_name(intake),
          workshop: %{date: workshop.date, start_time: workshop.start_time, venue: workshop.venue},
          fee_cents: fee_cents(intake, workshop, hold, holder?)
        }
    end
  end

  # A prepaid seat has no fee to show (ALE-388).
  defp fee_cents(_intake, _workshop, %IntakePayment{amount_cents: cents}, _holder?), do: cents
  defp fee_cents(%Intake{paid_via: "carried_fee"}, _workshop, nil, _holder?), do: nil
  defp fee_cents(%Intake{state: "contacted"}, _workshop, nil, true), do: nil
  defp fee_cents(_intake, workshop, nil, _holder?), do: workshop.fee_cents

  defp decide(%Intake{state: "paid"}, _workshop, _context, _reading),
    do: {:paid, :none, nil}

  defp decide(
         %Intake{state: "contacted"},
         %BeginnersWorkshop{status: "scheduled"} = w,
         %{hold: hold, returned: ret} = context,
         r
       ) do
    cond do
      hold && (expired?(hold, r) or returned_to?(hold, ret)) ->
        {:payment_in_progress, :check_again, nil}

      hold ->
        {:pay, :continue_payment, nil}

      context.holder? ->
        holder_page(w)

      not WorkshopPolicy.payment_open?(w, r) ->
        {:closed, :none, :payment_closed}

      not WorkshopPolicy.seat_free?(w, facts(w)) ->
        {:full, :check_again, nil}

      true ->
        {:pay, :pay, nil}
    end
  end

  defp decide(_intake, _workshop, _context, _reading), do: {:closed, :inactive}

  # A Carried Fee holder: the same seat rule as `confirm`, and never closed
  # by the cutoff.
  defp holder_page(workshop) do
    if WorkshopPolicy.seat_free?(workshop, facts(workshop)),
      do: {:confirm, :confirm, nil},
      else: {:full, :check_again, nil}
  end

  defp expired?(hold, reading), do: DateTime.compare(hold.expires_at, reading.now) != :gt

  defp returned_to?(%IntakePayment{stripe_checkout_session_id: id}, returned)
       when is_binary(id) and is_binary(returned),
       do: id == returned

  defp returned_to?(_hold, _returned), do: false

  defp holder?(%Intake{waitlist_id: nil}), do: false

  defp holder?(%Intake{waitlist_id: waitlist_id}),
    do:
      Repo.exists?(
        from(f in CarriedFee, where: f.waitlist_id == ^waitlist_id and f.status == "held")
      )

  defp open_hold(%Intake{id: id}),
    do: Repo.one(from(p in IntakePayment, where: p.intake_id == ^id and p.status == "open"))

  defp facts(%BeginnersWorkshop{id: id}), do: Map.fetch!(WorkshopFacts.load([id]), id)

  defp first_name(%Intake{waitlist_id: nil}), do: nil

  defp first_name(%Intake{waitlist_id: waitlist_id}) do
    Repo.one(
      from(p in UserProfile, where: p.waitlist_id == ^waitlist_id, limit: 1, select: p.first_name)
    )
  end
end
