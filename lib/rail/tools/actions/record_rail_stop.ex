defmodule Rail.Tools.Actions.RecordRailStop do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Schemas.Restart

  @doc """
  Records that Rail is going down, so the restart that follows knows how long it
  was away. `Rail.Tools.Boot` fills in the rest when it comes back.
  """
  def record_rail_stop do
    %Restart{}
    |> Restart.changeset(%{stopped_at: DateTime.utc_now()})
    |> Repo.insert()
  end
end
