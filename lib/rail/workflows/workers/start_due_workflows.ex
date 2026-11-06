defmodule Rail.Workflows.Workers.StartDueWorkflows do
  @moduledoc """
  The one-minute cron: reads every cloned project's workflow files, then queues a start for each due workflow.
  """
  use Oban.Worker, queue: :issues, max_attempts: 1

  alias Rail.Git
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Workflows
  alias Rail.Workflows.Workers.StartWorkflow

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for project <- Projects.list_projects(Scope.for_system()), Git.git_repo?(project.clone_path) do
      with {:error, reason} <- Workflows.sync_workflows(project) do
        Logger.warning("Could not read #{project.name}'s workflows: #{reason}")
      end
    end

    {:ok, due} = Workflows.list_workflows(Scope.for_system(), due: DateTime.utc_now())

    for workflow <- due do
      %{workflow_id: workflow.id} |> StartWorkflow.new() |> Oban.insert!()
    end

    :ok
  end
end
