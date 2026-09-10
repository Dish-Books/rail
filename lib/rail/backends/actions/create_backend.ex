defmodule Rail.Backends.Actions.CreateBackend do
  @moduledoc false

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo

  def create_backend(_scope, attrs) do
    %Backend{}
    |> Backend.changeset(attrs)
    |> Repo.insert()
  end
end
