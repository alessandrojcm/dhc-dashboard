defmodule Dhc.Inventory.ClubCalendar do
  @moduledoc """
  The club's calendar day — ALE-285.

  Loan dates are **calendar dates in `Europe/Dublin`** (spec ALE-273), not
  UTC days: a request submitted at 00:30 Dublin time in summer is still
  "today", even though UTC has not reached that date yet. Every date
  comparison in the loan domain (requestable dates, derived overdue) has to
  agree on which day it is, so it lives here rather than being re-derived
  per call site.

  The zone conversion is done by Postgres. Elixir's standard library needs a
  time-zone database to resolve `Europe/Dublin`, and this application
  deliberately ships none (see the Elixir date/time guidance in
  `apps/phoenix/AGENTS.md`); the database we already depend on carries the
  full IANA data and applies the summer-time offset for us.
  """

  alias Dhc.Repo

  @zone "Europe/Dublin"

  @doc """
  Today's date in the club's time zone.
  """
  @spec today() :: Date.t()
  def today do
    %{rows: [[%Date{} = today]]} =
      Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [@zone])

    today
  end

  @doc """
  The club's time-zone name, for documentation and error messages.
  """
  @spec zone() :: String.t()
  def zone, do: @zone
end
