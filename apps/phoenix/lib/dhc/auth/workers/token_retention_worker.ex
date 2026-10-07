defmodule Dhc.Auth.Workers.TokenRetentionWorker do
  @moduledoc """
  Daily cron driver for `Dhc.Auth.Retention.prune/1`: deletes expired
  `principal_tokens` rows and stale magic-link rate-limit windows in batches.

  A missed or failed pass is harmless; the next one deletes everything that
  has expired since. `unique` over incomplete states keeps overlapping ticks
  from piling up.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  require Logger

  alias Dhc.Auth.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{principal_tokens: tokens, rate_limit_windows: windows} = Retention.prune()

    Logger.info("Auth retention pass deleted #{tokens} tokens and #{windows} rate-limit windows")

    :ok
  end
end
