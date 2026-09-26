defmodule Rail.Projects.Actions.ListSlackWorkspaces do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo

  def list_slack_workspaces do
    Repo.all(from w in SlackWorkspace, order_by: [asc: w.name, asc: w.inserted_at])
  end
end
