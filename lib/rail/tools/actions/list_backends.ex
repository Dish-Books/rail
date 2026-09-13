defmodule Rail.Tools.Actions.ListBackends do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  def list_backends do
    Repo.all(Backend)
  end
end
