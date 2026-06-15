defmodule Dhc.Repo do
  use Ecto.Repo,
    otp_app: :dhc,
    adapter: Ecto.Adapters.Postgres
end
