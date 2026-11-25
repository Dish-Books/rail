defmodule RailWeb.Mcp.TaskJSON do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @doc "Tasks with their issue and its owner loaded."
  def index(%{tasks: tasks}), do: %{tasks: Enum.map(tasks, &task/1)}

  defp task(%Task{issue: %Issue{} = issue} = task) do
    %{
      identifier: issue.identifier,
      title: issue.title,
      stage: Task.stage_label(task),
      assignee: assignee(issue.owner_user),
      branch: branch(task),
      pull_request: task.pr_url,
      started_at: task.inserted_at
    }
  end

  defp assignee(%User{login: login}), do: login
  defp assignee(nil), do: nil

  # A split's children carry the work, so its own worktree name is no branch anyone pushes to.
  defp branch(%Task{stage: :split}), do: nil
  defp branch(%Task{worktree_name: name}), do: name
end
