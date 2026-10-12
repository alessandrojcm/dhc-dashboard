defmodule Dhc.BeginnersWorkshops.Commands.Facts do
  @moduledoc """
  The person's Carried Fee reads that `IntakePolicy` and `CarriedFeePolicy`
  facts are built from, under the person's entry lock (every fee writer
  holds it), and the read-only locked read of the parity seams (ALE-405).

    * `fee_refund/1`, `latest_fee/1`, `fee_refunded?/1` —
      `Commands.IntakeCommands` (`policy_facts/3`) and `Commands.People`
      (the Waitlist tab's facts and the link check);
    * `held?/1` — `Commands.Batches` (Fast-track after the cutoff) and
      `Commands.Payments` (`start_payment`'s `:confirm_instead`);
    * `read_locked/2` — the parity seams `locked_intake_facts/3`
      (`Commands.IntakeCommands`) and `locked_carried_fee_facts/2`
      (`Commands.People`).

  Reach lets only `Commands` and `Commands.*` call this module.
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol, only: [transact: 1, with_locked: 2]

  alias Dhc.BeginnersWorkshops.{CarriedFee, IntakeRefund}
  alias Dhc.Repo

  @doc false
  # A fee's latest refund (`IntakeRefund.latest_of_fees_query/1`); every
  # refund writer of a fee holds its lock, which the caller holds.
  @spec fee_refund(CarriedFee.t() | nil) :: IntakeRefund.t() | nil
  def fee_refund(nil), do: nil

  def fee_refund(%CarriedFee{id: id}) do
    case Repo.one(IntakeRefund.latest_of_fees_query([id])) do
      {^id, refund} -> refund
      nil -> nil
    end
  end

  @doc false
  # With no live fee: the person's latest one, if any. Every fee writer
  # holds the person's entry lock.
  @spec latest_fee(binary()) :: CarriedFee.t() | nil
  def latest_fee(waitlist_id) do
    from(f in CarriedFee,
      where: f.waitlist_id == ^waitlist_id,
      order_by: [desc: f.status_changed_at, desc: f.created_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc false
  # With no live fee: whether the person's latest Carried Fee was refunded,
  # so a repeated `refund_carried_fee` is already done. Every fee writer
  # holds the person's entry lock, which the refund commands hold too.
  @spec fee_refunded?(binary()) :: boolean()
  def fee_refunded?(waitlist_id),
    do: match?(%CarriedFee{status: "refunded"}, latest_fee(waitlist_id))

  @doc false
  @spec held?(CarriedFee.t() | nil) :: boolean()
  def held?(%CarriedFee{status: "held"}), do: true
  def held?(_no_held_fee), do: false

  @doc false
  # Locks `spec` and returns what `read` makes of the rows; nothing is
  # written.
  @spec read_locked(map(), (map() -> term())) :: {:ok, term()} | {:error, term()}
  def read_locked(spec, read), do: transact(fn -> with_locked(spec, &{:ok, read.(&1)}) end)
end
