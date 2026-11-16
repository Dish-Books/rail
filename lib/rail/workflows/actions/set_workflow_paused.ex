defmodule Rail.Workflows.Actions.SetWorkflowPaused do
  @moduledoc false

  import Rail.Workflows.Utils.BroadcastWorkflowsChanged

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Workflows.Schemas.Workflow

  @doc """
  Pauses or resumes `workflow` and returns it as saved, or `{:error, :not_found}` when the scope cannot access its
  project. It sets the state given rather than flipping it, so a double click or a second tab sets it twice.
  """
  def set_workflow_paused(%Scope{} = scope, %Workflow{project: %Project{} = project} = workflow, paused)
      when is_boolean(paused) do
    if Scope.can_access_project?(scope, workflow.project_id) do
      with {:ok, workflow} <- workflow |> Workflow.pause_changeset(paused) |> Repo.update() do
        broadcast_workflows_changed(project)
        {:ok, workflow}
      end
    else
      {:error, :not_found}
    end
  end
end
