defmodule Rail.Repo do
  use Ecto.Repo,
    otp_app: :rail,
    adapter: Ecto.Adapters.Postgres
end
