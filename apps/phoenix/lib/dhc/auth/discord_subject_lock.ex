defmodule Dhc.Auth.DiscordSubjectLock do
  @moduledoc false

  alias Dhc.Repo

  @doc "Serializes every transaction that can bind one Discord identity to a Principal."
  @spec lock_principal!(Ecto.UUID.t()) :: :ok
  def lock_principal!(principal_id) when is_binary(principal_id) and principal_id != "" do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["discord/principal/" <> principal_id],
      log: false
    )

    :ok
  end

  @doc "Serializes every transaction that can bind or reserve one Discord subject."
  @spec lock!(String.t()) :: :ok
  def lock!(subject) when is_binary(subject) and subject != "" do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["discord/subject/discord/" <> subject],
      log: false
    )

    :ok
  end
end
