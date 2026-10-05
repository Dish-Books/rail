defmodule Rail.Pipeline.Actions.StartTask do
  @moduledoc """
  Starts an issue's task at Plan, where every task begins.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Creates the task for `issue` at Plan, starts its run and returns `{:ok, task}`.
  """
  def start_task(%Issue{} = issue, :plan) do
    with {:ok, %OsProcess{task_id: task_id}} <- Pipeline.start_plan_run(issue) do
      Pipeline.get_task(task_id)
    end
  end
end
