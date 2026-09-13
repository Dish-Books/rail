defmodule Rail.Tools.Actions.ListBackends do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  # In the order they were added, so a newly saved backend lands at the end.
  def list_backends do
    Repo.all(from b in Backend, order_by: [asc: b.inserted_at, asc: b.id])
  end
end
