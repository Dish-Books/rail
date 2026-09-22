defmodule Rail.Pipeline.Utils.OpenPullRequest do
  @moduledoc """
  Opens a task's pull request once its branch is on the remote, as a draft, which
  keeps people and review bots off it while Rail's own review and QA run.

  A pull request is not what the stage is for, so one that cannot be opened is
  said in the run's log and tried again on the next push, never a failure.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Opens `task`'s pull request unless it has one, adopting an open one on its
  branch rather than opening a second. Returns the task as it now stands.
  """
  def open_pull_request(%Task{pr_number: number} = task, %Run{}) when is_integer(number), do: task

  def open_pull_request(%Task{} = task, %Run{} = run) do
    %Task{project: %Project{} = project} = task = Repo.preload(task, [:project, :issue])

    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, %{"number" => number} = pull_request} <- find_or_create(token, task) do
      attrs = %{pr_number: number, pr_url: pull_request["html_url"], pr_is_draft: pull_request["draft"]}
      {:ok, task} = task |> Task.changeset(attrs) |> Repo.update()
      task
    else
      {:error, reason} ->
        Pipeline.append_run_events(run.id, nil, ["[rail] Could not open the pull request: #{inspect(reason)}"])
        task
    end
  end

  defp find_or_create(token, %Task{project: %Project{} = project} = task) do
    case GitHub.find_pull_request(token, project.github_repo, task.worktree_name) do
      {:ok, nil} ->
        GitHub.create_pull_request(token, project.github_repo, %{
          title: "#{task.issue.identifier} #{task.issue.title}",
          head: task.worktree_name,
          base: project.default_branch,
          body: body(task.issue),
          draft: true
        })

      found ->
        found
    end
  end

  defp body(%Issue{url: url}) do
    ready = "Opened by Rail as a draft. It is marked ready for review once the change is ready to merge."
    if is_binary(url), do: "#{url}\n\n#{ready}", else: ready
  end
end
