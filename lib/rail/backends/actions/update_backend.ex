defmodule Rail.Backends.Actions.UpdateBackend do
  @moduledoc false

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo

  def update_backend(_scope, %Backend{} = backend, attrs) do
    backend
    |> Backend.changeset(attrs)
    |> Repo.update()
  end
end
