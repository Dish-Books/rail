defmodule Rail.Pipeline.Actions.StartTask do
  @moduledoc """
  Starts an issue's task: at Plan, where Rail cuts its own branch, or at Review on an open pull request a person
  hands over, whose branch Rail then works as pushed and never opens a second pull request for. An issue that
  already has its task gets that one back, so a second click or a second tab starts nothing.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BuildTask
  import Rail.Pipeline.Utils.StartChecks

  alias Rail.Git
  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Creates the task for `issue` at Plan, starts its run and returns `{:ok, task}`, or the issue's task when it has one.
  """
  def start_task(%Scope{} = scope, %Issue{} = issue, :plan) do
    with :ok <- accessible(scope, issue),
         nil <- current_task(issue),
         {:ok, %OsProcess{task_id: task_id}} <- Pipeline.start_plan_run(issue) do
      Pipeline.get_task(task_id)
    else
      %Task{id: task_id} -> Pipeline.get_task(task_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates the task for `issue` at Review on the open pull request `reference` names, by its number or its link, as
  the scope's user, and starts QA and the code reviewer on its latest commit. Returns `{:ok, task}`, the issue's task
  when it has one, or `{:error, reason}` naming why the pull request cannot be taken, with no task made.
  """
  def start_task(%Scope{} = scope, %Issue{} = issue, :review, reference) when is_binary(reference) do
    %Issue{project: %Project{} = project} = issue = Repo.preload(issue, :project)

    with :ok <- accessible(scope, issue),
         nil <- current_task(issue),
         {:ok, number} <- parse(reference, project),
         {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, pull_request} <- read(token, project, number),
         :ok <- takeable(pull_request, project),
         {:ok, task} <- insert(scope, issue, project, pull_request) do
      {:ok, task} = Pipeline.enter_stage(task, :review, start: false)
      :ok = start_checks(task)
      {:ok, _checked} = Pipeline.check_base(task)
      Pipeline.get_task(task.id)
    else
      %Task{id: task_id} -> Pipeline.get_task(task_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp accessible(%Scope{} = scope, %Issue{project_id: project_id}) do
    if Scope.can_access_project?(scope, project_id), do: :ok, else: {:error, :not_found}
  end

  defp current_task(%Issue{id: issue_id}) do
    Repo.one(from t in Task, where: t.issue_id == ^issue_id and is_nil(t.cleaned_up_at))
  end

  defp parse(reference, %Project{github_repo: repo}) do
    reference = String.trim(reference)

    cond do
      match = Regex.run(~r/\A#?(\d+)\z/, reference) ->
        {:ok, String.to_integer(Enum.at(match, 1))}

      match = Regex.run(~r{\A(?:https?://)?(?:www\.)?github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)(?:[/?#]\S*)?\z}i, reference) ->
        [_whole, linked, number] = match

        if String.downcase(linked) == String.downcase(repo),
          do: {:ok, String.to_integer(number)},
          else: {:error, {:other_repository, linked}}

      true ->
        {:error, :not_a_pull_request}
    end
  end

  defp read(token, %Project{github_repo: repo}, number) do
    case GitHub.get_pull_request(token, repo, number) do
      {:ok, pull_request} -> {:ok, pull_request}
      {:error, {:github_api_error, 404, _body}} -> {:error, {:no_pull_request, repo, number}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Rail pushes its fixes to the branch and merges it into the default branch, so it takes only a branch it can do
  # both with, and one no other task works on.
  defp takeable(%{"number" => number} = pull_request, %Project{} = project) do
    head = pull_request["head"]

    cond do
      pull_request["merged"] == true ->
        {:error, {:pull_request_merged, number}}

      pull_request["state"] != "open" ->
        {:error, {:pull_request_closed, number}}

      not same_repository?(head["repo"], project) ->
        {:error, {:pull_request_from_fork, number}}

      pull_request["base"]["ref"] != project.default_branch ->
        {:error, {:pull_request_into, number, pull_request["base"]["ref"], project.default_branch}}

      taker = taken_by(project, number, head["ref"]) ->
        {:error, {:pull_request_taken, number, taker.issue.identifier}}

      true ->
        :ok
    end
  end

  defp same_repository?(%{"full_name" => name}, %Project{github_repo: repo}) when is_binary(name),
    do: String.downcase(name) == String.downcase(repo)

  defp same_repository?(_deleted_fork, %Project{}), do: false

  # The branch names the worktree, so a task on the same branch is working on it whatever its pull request.
  defp taken_by(%Project{id: project_id}, number, branch) do
    Repo.one(
      from(t in Task,
        where:
          t.project_id == ^project_id and is_nil(t.cleaned_up_at) and
            (t.pr_number == ^number or t.worktree_name == ^branch),
        preload: :issue,
        limit: 1
      )
    )
  end

  # The task, its first round and the branch land together or not at all. Of two tabs handing over at once the
  # second's insert waits on the first's, then finds the issue's task taken and opens that one.
  defp insert(%Scope{user: user}, %Issue{} = issue, %Project{} = project, %{"head" => head} = pull_request) do
    user_id = user && user.id

    attrs = %{
      stage: :review,
      worktree_name: head["ref"],
      worktree_path: Path.join(project.clone_path, ".worktrees/#{head["ref"]}"),
      pr_number: pull_request["number"],
      pr_url: pull_request["html_url"],
      pr_is_draft: pull_request["draft"] == true,
      submitted_by_id: user_id,
      submitted_at: DateTime.utc_now(),
      submitted_head: head["sha"]
    }

    result =
      Repo.transaction(fn ->
        with {:ok, task} <- project |> build_task(issue, attrs) |> Repo.insert(),
             {:ok, round} <- Pipeline.create_round(task),
             # There is no plan, so the ticket is the whole specification, and handing the work over approves it.
             {:ok, _round} <-
               round
               |> Round.approve_changeset(user_id)
               |> Ecto.Changeset.put_embed(:ticket, ticket(issue))
               |> Repo.update(),
             :ok <- Git.fetch_default_branch(project, project.clone_path),
             :ok <- Git.track_remote_branch(project, head["ref"]) do
          task
        else
          {:error, %Ecto.Changeset{errors: [issue_id: _taken]}} -> Repo.rollback(:started)
          {:error, output} when is_binary(output) -> Repo.rollback({:branch_failed, output})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    if result == {:error, :started}, do: current_task(issue), else: result
  end

  defp ticket(%Issue{} = issue) do
    %Round.Ticket{
      title: issue.title,
      description: issue.description,
      priority: issue.priority,
      estimate: issue.estimate
    }
  end
end
