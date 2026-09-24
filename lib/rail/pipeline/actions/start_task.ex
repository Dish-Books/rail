defmodule Rail.Pipeline.Actions.StartTask do
  @moduledoc """
  Starts an issue's task at the stage a person picks: product, or straight to
  design or architect for an issue whose ticket is already written.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Creates the task for `issue` at `stage`, starts that stage's run and returns
  `{:ok, task}`.
  """
  def start_task(%Issue{} = issue, :product) do
    with {:ok, %OsProcess{task_id: task_id}} <- Pipeline.start_product_run(issue) do
      Pipeline.get_task(task_id)
    end
  end

  def start_task(%Issue{} = issue, stage) when stage in [:design, :architect] do
    issue = Repo.preload(issue, :project)

    with {:ok, task} <- Pipeline.create_task(issue, stage),
         {:ok, _started} <- Pipeline.enter_stage(task, stage) do
      Pipeline.get_task(task.id)
    end
  end
end
