defmodule Rail.Tools.Actions.CreateBackend do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  def create_backend(_scope, attrs) do
    %Backend{}
    |> Backend.changeset(attrs)
    |> Repo.insert()
  end
end
