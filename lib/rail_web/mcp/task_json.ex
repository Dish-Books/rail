defmodule RailWeb.Mcp.TaskJSON do
  @moduledoc false

  import RailWeb.Utils.StageLabel, only: [stage_label: 2, waiting_path: 1]

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @doc "Tasks with their issue and its owner loaded, and the waits read for them by task id."
  def index(%{tasks: tasks, waits: waits}), do: %{tasks: Enum.map(tasks, &task(&1, waits[&1.id]))}

  defp task(%Task{issue: %Issue{} = issue} = task, wait) do
    %{
      identifier: issue.identifier,
      title: issue.title,
      stage: Task.stage_label(task),
      assignee: assignee(issue.owner_user),
      branch: branch(task),
      pull_request: task.pr_url,
      started_at: task.inserted_at,
      waiting: waiting(wait)
    }
  end

  defp waiting(%{run: %Run{task: %Task{} = waiting_task} = run, kind: kind, id: id, since: since}) do
    %{
      id: id,
      kind: kind,
      summary: stage_label(waiting_task, run),
      url: RailWeb.Endpoint.url() <> waiting_path(run),
      since: since
    }
  end

  defp waiting(nil), do: nil

  defp assignee(%User{login: login}), do: login
  defp assignee(nil), do: nil

  # A split's children carry the work, so its own worktree name is no branch anyone pushes to.
  defp branch(%Task{stage: :split}), do: nil
  defp branch(%Task{worktree_name: name}), do: name
end
