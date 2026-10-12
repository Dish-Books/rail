defmodule Rail.Workflows do
  @moduledoc """
  Public context for workflows: routine work a project keeps as files under `.rail/workflows/` on its default
  branch, each opening an issue and starting its task at Plan on a schedule. Rail only reads them, pauses them
  and runs them now; they are written in the repository.
  """

  use Rail.PermissionsDecorator

  alias Rail.Workflows.Actions

  @decorate can?(resource: :workflows, action: :list)
  defdelegate list_workflows(scope, opts), to: Actions.ListWorkflows

  @decorate can?(resource: :workflows, action: :manage)
  defdelegate set_workflow_paused(scope, workflow, paused), to: Actions.SetWorkflowPaused

  @decorate can?(resource: :workflows, action: :manage)
  defdelegate run_workflow_now(scope, workflow), to: Actions.RunWorkflowNow

  defdelegate sync_workflows(project), to: Actions.SyncWorkflows
  defdelegate start_workflow(workflow), to: Actions.StartWorkflow
end
