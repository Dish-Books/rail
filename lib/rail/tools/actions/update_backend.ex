defmodule Rail.Tools.Actions.UpdateBackend do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  def update_backend(_scope, %Backend{} = backend, attrs) do
    backend
    |> Backend.changeset(attrs)
    |> Repo.update()
  end
end
