defmodule Rail.Backends.Actions.ListBackends do
  @moduledoc false

  import Ecto.Query

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo

  def list_backends(_scope \\ nil) do
    Repo.all(from(b in Backend, order_by: [asc: b.name]))
  end
end
