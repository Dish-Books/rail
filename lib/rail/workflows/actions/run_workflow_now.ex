defmodule Rail.Workflows.Actions.RunWorkflowNow do
  @moduledoc false

  import Rail.Workflows.Utils.OpenWorkflowIssue

  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Workflows.Schemas.Workflow

  @doc """
  Run now: opens the workflow's issue dated today, paused or not, and leaves the next scheduled start where it was.
  Returns what `open_workflow_issue/2` did, or `{:error, :not_found}` when the scope cannot access its project.
  """
  def run_workflow_now(%Scope{} = scope, %Workflow{project: %Project{}} = workflow) do
    if Scope.can_access_project?(scope, workflow.project_id),
      do: open_workflow_issue(workflow, :now),
      else: {:error, :not_found}
  end
end
