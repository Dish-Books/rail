defmodule Rail.Pipeline.Actions.ListApprovals do
  @moduledoc """
  The approvals standing on a task's pull request, read from GitHub as the app so every viewer sees them,
  whoever gave them and wherever.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users

  @doc """
  Returns `{:ok, approvals}`, each `%{login, user, approved_at}` with the Rail user or nil, ordered by time and
  then login, or `{:error, reason}` when GitHub could not be read. A task with no pull request has none.
  """
  def list_approvals(%Task{pr_number: nil}), do: {:ok, []}

  def list_approvals(%Task{} = task) do
    %Task{project: %Project{} = project} = Repo.preload(task, :project)

    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, reviews} <- GitHub.list_reviews(token, project.github_repo, task.pr_number) do
      # A comment leaves a reviewer's verdict standing, and GitHub turns a dismissed approval's state to DISMISSED.
      latest =
        for %{"user" => %{"login" => "" <> login}, "state" => state, "submitted_at" => "" <> at} <- reviews,
            state in ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"],
            {:ok, submitted_at, _offset} <- [DateTime.from_iso8601(at)],
            reduce: %{} do
          latest -> Map.put(latest, login, {state, submitted_at})
        end

      approved = Enum.filter(latest, &match?({_login, {"APPROVED", _at}}, &1))

      users = approved |> Enum.map(&elem(&1, 0)) |> Users.list_users_by_logins() |> Map.new(&{&1.login, &1})

      approvals =
        approved
        |> Enum.map(fn {login, {"APPROVED", at}} -> %{login: login, user: users[login], approved_at: at} end)
        |> Enum.sort_by(&{DateTime.to_unix(&1.approved_at, :microsecond), &1.login})

      {:ok, approvals}
    end
  end
end
