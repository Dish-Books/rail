defmodule Rail.Workflows.Workers.StartWorkflow do
  @moduledoc """
  Starts one due workflow. It runs once, since a failed start waits for the next due time, and is unique on the
  row while incomplete, so the next minute's cron queues no second one behind it.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 1,
    unique: [keys: [:workflow_id], states: :incomplete, period: :infinity]

  alias Rail.Repo
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_id" => workflow_id}}) do
    workflow = Workflow |> Repo.get!(workflow_id) |> Repo.preload(:project)

    case Workflows.start_workflow(workflow) do
      {:ok, _issue} ->
        :ok

      {:error, reason} when reason in [:not_due, :invalid, :paused, :project_inactive] ->
        :ok

      {:error, {:unfinished, _issue}} ->
        :ok

      {:error, reason} ->
        Logger.warning("#{workflow.path} in #{workflow.project.name} opened nothing: #{inspect(reason)}")
        :ok
    end
  end
end
