defmodule Rail.Issues.Actions.HandleGithubWebhook do
  @moduledoc """
  A pull request merged into a project's default branch moves the issues it belongs to toward Done.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Applies `payload` of GitHub `event` to `project`. A merged pull request moves each issue whose or whose task's pull
  request number or branch it carries forward to Done, at most once. Anything else is ignored.
  """
  # Cleaned-up tasks count, since Rail's Merge cleans its task up before GitHub's delivery may arrive.
  def handle_github_webhook(%Project{default_branch: base} = project, "pull_request", %{
        "action" => "closed",
        "pull_request" => %{"merged" => true, "number" => number, "head" => %{"ref" => head}, "base" => %{"ref" => base}}
      }) do
    from(i in Issue,
      left_join: t in Task,
      on: t.issue_id == i.id and t.project_id == ^project.id,
      where: i.project_id == ^project.id,
      where: i.pr_number == ^number or t.pr_number == ^number or i.branch_name == ^head or t.worktree_name == ^head,
      distinct: true,
      order_by: [asc: i.id]
    )
    |> Repo.all()
    |> Enum.each(&Tracker.advance_issue(&1, :done))
  end

  def handle_github_webhook(%Project{}, _event, _payload), do: :ok
end
