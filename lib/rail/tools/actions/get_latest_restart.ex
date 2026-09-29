defmodule Rail.Tools.Actions.GetLatestRestart do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.Restart

  @doc "The newest restart, whether or not Rail has come back from it yet."
  def get_latest_restart do
    case Repo.one(from r in Restart, order_by: [desc: r.inserted_at, desc: r.id], limit: 1) do
      %Restart{} = restart -> {:ok, restart}
      nil -> {:error, :not_found}
    end
  end
end
