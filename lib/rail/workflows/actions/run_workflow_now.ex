defmodule Rail.Workflows.Actions.RunWorkflowNow do
  @moduledoc false

  import Rail.Workflows.Utils.OpenWorkflowIssue

  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Workflows.Schemas.Workflow

  @doc """
  Run now: opens the workflow's issue dated today, paused or not, and leaves the next scheduled start where it was.
  Returns what `open_workflow_issue/2` did, `{:error, :not_found}` when the scope cannot access its project, or
  `{:error, :github_required}` for someone without GitHub.
  """
  def run_workflow_now(%Scope{} = scope, %Workflow{project: %Project{}} = workflow) do
    cond do
      not Scope.can_access_project?(scope, workflow.project_id) -> {:error, :not_found}
      match?(%Scope{user: %{github_id: nil}}, scope) -> {:error, :github_required}
      true -> open_workflow_issue(workflow, :now)
    end
  end
end
