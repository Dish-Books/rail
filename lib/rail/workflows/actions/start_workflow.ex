defmodule Rail.Workflows.Actions.StartWorkflow do
  @moduledoc false

  import Rail.Workflows.Utils.OpenWorkflowIssue

  alias Rail.Projects.Schemas.Project
  alias Rail.Workflows.Schemas.Workflow

  @doc """
  The scheduled start: opens the workflow's issue for the slot it is due at, if it still is, and moves the due time on.
  Returns what `open_workflow_issue/2` did.
  """
  def start_workflow(%Workflow{project: %Project{}} = workflow), do: open_workflow_issue(workflow, :scheduled)
end
