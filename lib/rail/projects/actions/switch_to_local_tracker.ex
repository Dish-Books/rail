defmodule Rail.Projects.Actions.SwitchToLocalTracker do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Puts the project on Rail's own tracker under `key`. Only the move's worker calls it, inside the transaction that moves
  the tickets, so it broadcasts nothing: the worker announces both once they commit.
  """
  def switch_to_local_tracker(%Project{} = project, key) do
    project
    |> Project.local_tracker_changeset(key)
    |> Repo.update()
  end
end
