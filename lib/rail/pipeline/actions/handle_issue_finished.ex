defmodule Rail.Pipeline.Actions.HandleIssueFinished do
  @moduledoc """
  Queues the split's next step when a child's issue finishes, so the Linear webhook answers without waiting on it.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Repo

  @doc """
  Inserts an `AdvanceSplit` job for the parent of `issue`'s task and returns `{:ok, job}`, or `:ok`
  when the issue is not a child of a split.
  """
  def handle_issue_finished(%Issue{id: issue_id}) do
    query = from(t in Task, where: t.issue_id == ^issue_id and not is_nil(t.parent_task_id), select: t.parent_task_id)

    case Repo.all(query) do
      [parent_task_id | _cleaned_up] -> %{parent_task_id: parent_task_id} |> AdvanceSplit.new() |> Oban.insert()
      [] -> :ok
    end
  end
end
