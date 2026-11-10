defmodule Dhc.Invitations.Validity do
  @moduledoc """
  The one owner of how long an Invitation stays valid.

  Every place that stamps `invitations.expires_at` — issuing a fresh
  Invitation (`Dhc.Invitations.Repository.insert_pending_invitation/3`) and
  re-arming one on resend (`Dhc.Invitations`) — reads its window from here, so
  the validity a member gets is the same on both paths.

  The window is configurable with `:invitation_validity_days` (see
  `config/config.exs`); a missing or invalid value falls back to the seven-day
  default. The invite email copy in
  `packages/email-templates/emails/invite-member.tsx` states the same number —
  change both together.
  """

  @default_validity_days 7

  @doc """
  How many days an Invitation stays valid from the moment it is issued or
  re-armed.
  """
  @spec days() :: pos_integer()
  def days do
    case Application.get_env(:dhc, :invitation_validity_days, @default_validity_days) do
      days when is_integer(days) and days > 0 -> days
      _other -> @default_validity_days
    end
  end

  @doc """
  The instant an Invitation issued (or re-armed) at `now` expires.
  """
  @spec expires_at(DateTime.t()) :: DateTime.t()
  def expires_at(now \\ DateTime.utc_now()) do
    now
    |> DateTime.add(days(), :day)
    |> DateTime.truncate(:second)
  end
end
