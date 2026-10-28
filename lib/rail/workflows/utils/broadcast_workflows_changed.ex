defmodule Rail.Workflows.Utils.BroadcastWorkflowsChanged do
  @moduledoc """
  Says on `"workflows"` that a project's workflows changed, once the write is committed.
  """

  alias Rail.Projects.Schemas.Project

  @doc """
  Broadcasts `{:workflows_changed, project_id}`.
  """
  def broadcast_workflows_changed(%Project{id: project_id}) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "workflows", {:workflows_changed, project_id})
  end
end
