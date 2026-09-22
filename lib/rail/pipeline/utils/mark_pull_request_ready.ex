defmodule Rail.Pipeline.Utils.MarkPullRequestReady do
  @moduledoc false

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  require Logger

  @doc """
  Takes `task`'s draft pull request out of draft, once the demo is settled.

  A pull request that will not come out of draft is not a reason to hold the task
  back, so a failure is logged and the task returned as it was.
  """
  def mark_pull_request_ready(%Task{pr_number: number, pr_is_draft: true} = task) when is_integer(number) do
    %Project{} = project = Repo.get!(Project, task.project_id)

    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, %{"node_id" => node_id}} <- GitHub.get_pull_request(token, project.github_repo, number),
         :ok <- GitHub.mark_pull_request_ready(token, node_id) do
      {:ok, task} = task |> Task.changeset(%{pr_is_draft: false}) |> Repo.update()
      task
    else
      {:error, reason} ->
        Logger.warning("Could not mark #{project.github_repo}##{number} ready for review: #{inspect(reason)}")
        task
    end
  end

  def mark_pull_request_ready(%Task{} = task), do: task
end
