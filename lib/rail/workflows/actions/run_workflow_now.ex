defmodule Rail.Workflows.Actions.RunWorkflowNow do
  @moduledoc false

  import Rail.Workflows.Utils.OpenWorkflowIssue

  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Workflows.Schemas.Workflow

  @doc """
  Run now: opens the workflow's issue dated today, paused or not, and leaves the next scheduled start where it was.
  Returns what `open_workflow_issue/2` did.
  """
  def run_workflow_now(%Scope{}, %Workflow{project: %Project{}} = workflow), do: open_workflow_issue(workflow, :now)
end
