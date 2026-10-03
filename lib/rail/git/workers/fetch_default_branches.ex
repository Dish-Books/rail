defmodule Rail.Git.Workers.FetchDefaultBranches do
  @moduledoc """
  Fetches every active project's default branch into its clone every fifteen
  minutes, so a merged prompt reaches the next run without waiting for a task to fetch.
  """
  use Oban.Worker, queue: :git, max_attempts: 1, unique: [period: 895]

  alias Rail.Git
  alias Rail.Projects
  alias Rail.Scope

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for project <- Projects.list_projects(Scope.for_system()), project.active and Git.git_repo?(project.clone_path) do
      case Git.fetch_default_branch(project, project.clone_path) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Could not fetch #{project.name}'s default branch: #{inspect(reason)}")
      end
    end

    :ok
  end
end
