defmodule Dhc.BeginnersWorkshops.IntakeReplies.ReplyActions do
  @moduledoc """
  The Reply Action table (ALE-411, ADR 0030): which command, if any, Jev's
  classified intent leads to for the person's state now. Pure: no storage,
  no clock, no configuration read except `config/0`.

  | Intent | Contacted, unpaid | Paid | Holds a Carried Fee | No open Intake |
  | -- | -- | -- | -- | -- |
  | `cant_make_date` | Decline | money back → Cancel with refund, else Deferral | — | — |
  | `leaving_waitlist` | Withdrawal | money back → Withdrawal with refund, else coordinator | same as Paid | Withdrawal |
  | `wants_refund` | — | Cancel with refund | Refund the Carried Fee | — |
  | `wants_to_come_back` | — | — | — | (ALE-412) |
  | `link_problem` | Resend link | Resend link | — | — |

  Money errs towards what can be undone: unclear money on "can't make it"
  is a Deferral, and on "leaving" with money to settle the coordinator
  decides. A Reply Action never forfeits (`withdraw` always carries
  `refund: true`).

  Intake intents (`cant_make_date`, `wants_refund` on a paid Intake,
  `link_problem`) act only while the Intake the email was about is still
  the person's open Intake (`binding_open`); person intents
  (`leaving_waitlist`, `wants_refund` on a held Carried Fee) act whichever
  email was answered.

  These facts are read without a lock and only choose the command: the
  boundary's locked `IntakePolicy`/`CarriedFeePolicy` re-check decides.
  """

  @typedoc """
  The person's state, read lock-free from their rows:

    * `binding_open` — the Intake the answered email was about is the
      person's open Intake;
    * `open_intake` — the state of the person's open Intake, if any;
    * `held_fee` — the person holds a `held` Carried Fee;
    * `standing` — their Waitlist status.
  """
  @type t :: %__MODULE__{
          binding_open: boolean(),
          open_intake: String.t() | nil,
          held_fee: boolean(),
          standing: String.t() | nil
        }

  @enforce_keys [:binding_open, :open_intake, :held_fee, :standing]
  defstruct @enforce_keys

  @type money :: :yes | :no | :unclear
  @type action ::
          {:intake, :decline | :defer | :cancel_with_refund | :resend_link}
          | {:person, :withdraw | :refund_carried_fee}
  @type decision :: {:ok, action()} | {:none, reason :: String.t()}

  @type config :: %{
          intents: %{String.t() => %{enabled: boolean(), threshold: number()}},
          money_back: %{yes: number(), no: number()}
        }

  # The intents that can lead to a command, in spec order (`something_else`
  # never does). `wants_to_come_back` joins with restore (ALE-412).
  @intents ~w(cant_make_date leaving_waitlist wants_refund wants_to_come_back link_problem)

  @default_threshold 0.9
  @default_money_back %{yes: 0.8, no: 0.2}

  @doc "Every intent the table has a row for, in spec order."
  @spec intents() :: [String.t()]
  def intents, do: @intents

  @doc """
  The intents that could lead to a command for this person now, whatever
  the money answer: what Jev is offered (with `something_else`).
  """
  @spec offered(t()) :: [String.t()]
  def offered(%__MODULE__{} = facts) do
    Enum.filter(@intents, fn intent ->
      Enum.any?([:yes, :no, :unclear], &match?({:ok, _}, action(intent, &1, facts)))
    end)
  end

  @doc "Whether any of `intents` is switched on."
  @spec any_enabled?([String.t()], config()) :: boolean()
  def any_enabled?(intents, config), do: Enum.any?(intents, &enabled?(&1, config))

  @doc """
  The decision for one classification (`intent`, `confidence`,
  `money_back`): `something_else`, a disabled intent and one below its
  threshold need the coordinator; otherwise the table decides with the
  money answer read through the `money_back` thresholds.
  """
  @spec decide(%{intent: String.t(), confidence: number(), money_back: number()}, t(), config()) ::
          decision()
  def decide(%{intent: "something_else"}, _facts, _config), do: {:none, "something_else"}

  def decide(%{intent: intent, confidence: confidence, money_back: money_back}, facts, config) do
    cond do
      not enabled?(intent, config) -> {:none, "intent_disabled"}
      confidence < threshold(intent, config) -> {:none, "below_threshold"}
      true -> action(intent, money(money_back, config), facts)
    end
  end

  @doc "The `money_back` answer: yes at or above `yes`, no at or below `no`, else unclear."
  @spec money(number(), config()) :: money()
  def money(value, %{money_back: %{yes: yes, no: no}}) do
    cond do
      value >= yes -> :yes
      value <= no -> :no
      true -> :unclear
    end
  end

  @doc "The table: what `intent` with this money answer leads to for this person."
  @spec action(String.t(), money(), t()) :: decision()
  def action("something_else", _money, _facts), do: {:none, "something_else"}

  def action("cant_make_date", money, %__MODULE__{} = facts) do
    intake_action(facts, fn
      "contacted" -> :decline
      "paid" when money == :yes -> :cancel_with_refund
      "paid" -> :defer
    end)
  end

  def action("leaving_waitlist", money, %__MODULE__{} = facts) do
    if facts.open_intake == "paid" or facts.held_fee,
      do: leaving_with_money(money),
      else: leaving(facts)
  end

  def action("wants_refund", _money, %__MODULE__{open_intake: "paid"} = facts),
    do: intake_action(facts, fn _paid -> :cancel_with_refund end)

  def action("wants_refund", _money, %__MODULE__{held_fee: true}),
    do: {:ok, {:person, :refund_carried_fee}}

  def action("link_problem", _money, %__MODULE__{} = facts) do
    intake_action(facts, fn _open -> :resend_link end)
  end

  def action(_intent, _money, %__MODULE__{}), do: {:none, "no_reply_action"}

  # Leaving with money to settle: only a clear "money back" acts, since a
  # Reply Action never forfeits.
  defp leaving_with_money(:yes), do: {:ok, {:person, :withdraw}}
  defp leaving_with_money(:no), do: {:none, "money_not_asked"}
  defp leaving_with_money(:unclear), do: {:none, "money_unclear"}

  # Leaving with no money to settle: a contacted person, or someone still
  # waiting with no open Intake.
  defp leaving(%__MODULE__{open_intake: "contacted"}), do: {:ok, {:person, :withdraw}}

  defp leaving(%__MODULE__{open_intake: nil, standing: "waiting"}),
    do: {:ok, {:person, :withdraw}}

  defp leaving(%__MODULE__{}), do: {:none, "no_reply_action"}

  # An Intake intent: only on the answered email's Intake while it is the
  # person's open one (`contacted` or `paid`). `command` names the command
  # for the open state.
  defp intake_action(%__MODULE__{open_intake: nil}, _command), do: {:none, "no_reply_action"}

  defp intake_action(%__MODULE__{binding_open: false}, _command), do: {:none, "intake_not_open"}

  defp intake_action(%__MODULE__{open_intake: state}, command),
    do: {:ok, {:intake, command.(state)}}

  defp enabled?(intent, config), do: get_in(config, [:intents, intent, :enabled]) == true

  defp threshold(intent, config),
    do: get_in(config, [:intents, intent, :threshold]) || @default_threshold

  @doc """
  The configuration (`config :dhc, #{inspect(__MODULE__)}`): per intent
  `enabled` (default `false`) and `threshold` (default
  #{@default_threshold}), and the `money_back` `yes`/`no` thresholds
  (default #{@default_money_back.yes}/#{@default_money_back.no}). An
  invalid value falls back to its default, and an intent is never switched
  on by a malformed entry.
  """
  @spec config() :: config()
  def config do
    configured = Application.get_env(:dhc, __MODULE__, [])

    intents =
      configured |> Keyword.get(:intents, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    %{
      intents: Map.new(@intents, &{&1, intent_config(Map.get(intents, &1))}),
      money_back: money_back_config(Keyword.get(configured, :money_back))
    }
  end

  defp intent_config(entry) when is_list(entry) or is_map(entry) do
    entry = Map.new(entry)

    %{
      enabled: Map.get(entry, :enabled) == true,
      threshold: probability(Map.get(entry, :threshold), @default_threshold)
    }
  end

  defp intent_config(_missing), do: %{enabled: false, threshold: @default_threshold}

  defp money_back_config(entry) when is_list(entry) or is_map(entry) do
    entry = Map.new(entry)
    yes = probability(Map.get(entry, :yes), @default_money_back.yes)
    no = probability(Map.get(entry, :no), @default_money_back.no)
    if no < yes, do: %{yes: yes, no: no}, else: @default_money_back
  end

  defp money_back_config(_missing), do: @default_money_back

  defp probability(value, _default) when is_number(value) and value >= 0 and value <= 1,
    do: value

  defp probability(_value, default), do: default
end
