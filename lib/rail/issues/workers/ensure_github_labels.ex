defmodule Rail.Issues.Workers.EnsureGithubLabels do
  @moduledoc """
  Makes the `rail:` labels in a GitHub project's repository, with their colors and descriptions,
  so they are there before an issue first needs one. Ones that exist are left as they are.
  """
  use Oban.Worker, queue: :issues, max_attempts: 5, unique: [keys: [:project_id], states: :incomplete]

  import Rail.Issues.Utils.GithubIssueLabels

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id}}) do
    with %Project{tracker: :github} = project <- Repo.get(Project, project_id),
         {:ok, token} <- GitHub.installation_token(project.github_installation_id) do
      Enum.reduce_while(github_issue_labels(), :ok, fn label, :ok ->
        attrs = Map.take(label, [:name, :color, :description])

        case GitHub.create_label(token, project.github_repo, attrs) do
          {:ok, _created_or_existing} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      %Project{} -> :ok
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
