defmodule Dhc.BeginnersWorkshops.Clock do
  @moduledoc """
  The one clock of `Dhc.BeginnersWorkshops`, built on `Dhc.ClubCalendar`.

  Commands receive a clock through `opts[:clock]` and call `read/1` *inside*
  the lock, never before it, so every decision and stamp uses an instant
  taken while the rows it judges are held (the Training Announcements
  precedent, ADR 0026). Tests pass `fixed/1`.
  """

  alias Dhc.ClubCalendar

  @enforce_keys [:tick]
  defstruct [:tick]

  @type t :: %__MODULE__{tick: (-> DateTime.t())}

  @typedoc "One reading: the instant, its Dublin date and its Dublin wall-clock time."
  @type reading :: %{now: DateTime.t(), today: Date.t(), now_time: Time.t()}

  @doc "The wall clock."
  @spec system() :: t()
  def system, do: %__MODULE__{tick: &DateTime.utc_now/0}

  @doc "A clock that always reads `now` (tests and reads)."
  @spec fixed(DateTime.t()) :: t()
  def fixed(%DateTime{} = now), do: %__MODULE__{tick: fn -> now end}

  @doc "Reads the clock: the instant plus its Dublin date and time."
  @spec read(t()) :: reading()
  def read(%__MODULE__{tick: tick}) do
    now = tick.()
    %{now: now, today: ClubCalendar.on_date(now), now_time: ClubCalendar.time_on(now)}
  end

  @doc "The clock in `opts`, or the wall clock."
  @spec from_opts(keyword()) :: t()
  def from_opts(opts), do: Keyword.get_lazy(opts, :clock, &system/0)
end
