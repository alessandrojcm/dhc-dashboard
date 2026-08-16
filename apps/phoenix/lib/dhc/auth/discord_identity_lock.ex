defmodule Dhc.Auth.DiscordIdentityLock do
  @moduledoc false

  alias Dhc.Repo

  @doc "Takes the first advisory lock for a Discord mutation when a Principal is known."
  @spec lock_principal!(Ecto.UUID.t()) :: :ok
  def lock_principal!(principal_id) when is_binary(principal_id) and principal_id != "" do
    lock_key!("discord/principal/" <> principal_id)
  end

  @doc "Serializes every transaction that can bind or reserve one provider subject."
  @spec lock_subject!(String.t(), String.t()) :: :ok
  def lock_subject!(provider \\ "discord", subject)

  def lock_subject!(provider, subject)
      when is_binary(provider) and provider != "" and is_binary(subject) and subject != "" do
    lock_key!("discord/subject/#{provider}/#{subject}")
  end

  defp lock_key!(key) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [key],
      log: false
    )

    :ok
  end
end
