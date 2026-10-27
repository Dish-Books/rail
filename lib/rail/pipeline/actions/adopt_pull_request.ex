defmodule Rail.Pipeline.Actions.AdoptPullRequest do
  @moduledoc """
  Starts an issue's task at Review on the pull request its work was opened as outside Rail, so the change goes
  through Review's rounds as one Rail built would. Nothing was planned, so round 1 holds the issue as its ticket.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BuildTask
  import Rail.Pipeline.Utils.PrepareWorktree
  import Rail.Pipeline.Utils.StartChecks

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Adopts the open pull request `Issues.link_pull_request/2` finds for `issue` as its task and starts the round's
  checks, looking it up again since the issue's link may be stale.
  Returns `{:ok, task}`, or `{:error, reason}`: `:not_found`, `:task_exists`, `:no_pull_request`,
  `:pull_request_from_fork`, `{:pull_request_base, base}`, `:pull_request_taken`, or what GitHub or git refused.
  """
  def adopt_pull_request(%Scope{user: user} = scope, %Issue{} = issue) do
    %Issue{project: %Project{} = project} = issue = Repo.preload(issue, [:project, :task], force: true)

    with :ok <- accessible(scope, issue),
         {:ok, pull_request} <- Issues.link_pull_request(scope, issue),
         true <- is_map(pull_request) || {:error, :no_pull_request},
         {:ok, branch} <- adoptable(pull_request, project),
         :ok <- Git.fetch_branch(project, branch),
         {:ok, task} <- insert(project, issue, pull_request, branch, user),
         # Claimed before the checks start, so they share one slot rather than each claiming its own.
         {:ok, task, _worktree_path} <- prepare_worktree(project, task) do
      {:ok, task} = Pipeline.enter_stage(task, :review, start: false)
      {:ok, task} = Pipeline.check_base(task)
      :ok = start_checks(task)
      {:ok, task}
    end
  end

  defp accessible(%Scope{} = scope, %Issue{project_id: project_id, task: task}) do
    cond do
      not Scope.can_access_project?(scope, project_id) -> {:error, :not_found}
      is_struct(task, Task) -> {:error, :task_exists}
      true -> :ok
    end
  end

  # Rail pushes the review's fixes to the branch and reads it against the default branch.
  defp adoptable(%{"head" => head, "base" => base}, %Project{} = project) do
    cond do
      not same_repo?(get_in(head, ["repo", "full_name"]), project.github_repo) -> {:error, :pull_request_from_fork}
      base["ref"] != project.default_branch -> {:error, {:pull_request_base, base["ref"]}}
      taken?(project, head["ref"]) -> {:error, :pull_request_taken}
      true -> {:ok, head["ref"]}
    end
  end

  defp taken?(%Project{id: project_id}, branch) do
    Repo.exists?(
      from t in Task, where: t.project_id == ^project_id and t.worktree_name == ^branch and is_nil(t.cleaned_up_at)
    )
  end

  defp insert(%Project{} = project, %Issue{} = issue, pull_request, branch, user) do
    Repo.transaction(fn ->
      attrs = %{
        stage: :review,
        worktree_name: branch,
        worktree_path: Path.join(project.clone_path, ".worktrees/#{branch}"),
        pr_number: pull_request["number"],
        pr_url: pull_request["html_url"],
        pr_is_draft: pull_request["draft"]
      }

      with {:ok, task} <- project |> build_task(issue, attrs) |> Repo.insert(),
           {:ok, round} <- Pipeline.create_round(task),
           # Whoever adopts it vouches for the change in place of a plan, so Merge does not wait on one.
           {:ok, _approved} <-
             round
             |> Round.approve_changeset(user && user.id)
             |> Ecto.Changeset.put_embed(:ticket, %Round.Ticket{
               title: issue.title,
               description: issue.description || "",
               priority: issue.priority,
               estimate: issue.estimate
             })
             |> Repo.update(),
           # In the transaction, so an issue whose branch will not check out is left without a task to start again.
           {:ok, _worktree_path} <- Git.get_or_create_worktree(project, task) do
        task
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp same_repo?(one, other) when is_binary(one) and is_binary(other), do: String.downcase(one) == String.downcase(other)
  defp same_repo?(_one, _other), do: false
end
