defmodule Dhc.Auth.DiscordSubjectLock do
  @moduledoc false

  alias Dhc.Repo

  @doc "Serializes every transaction that can bind or reserve one Discord subject."
  @spec lock!(String.t()) :: :ok
  def lock!(subject) when is_binary(subject) and subject != "" do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["discord:" <> subject],
      log: false
    )

    :ok
  end
end
