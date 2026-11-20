defmodule Rail.Support.Actions.ListIntercomWorkspaces do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Support.Schemas.IntercomWorkspace

  @doc """
  Every workspace, by name, with the project it feeds.
  """
  def list_intercom_workspaces do
    Repo.all(from w in IntercomWorkspace, order_by: [asc: w.name, asc: w.id], preload: :project)
  end
end
