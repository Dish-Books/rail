defmodule Rail.Pipeline.Utils.EnqueuePullRequest do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.OpenPullRequest

  @doc """
  Queues the job that opens `task`'s pull request and describes it, unless it has
  one already: a later push never describes it again.
  """
  def enqueue_pull_request(%Task{pr_number: nil} = task) do
    %{task_id: task.id}
    |> OpenPullRequest.new()
    |> Oban.insert()
  end

  def enqueue_pull_request(%Task{pr_number: number}) when is_integer(number), do: :ok
end
