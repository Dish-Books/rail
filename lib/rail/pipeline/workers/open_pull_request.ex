defmodule Rail.Pipeline.Workers.OpenPullRequest do
  @moduledoc """
  Opens a task's pull request once its branch is on the remote, as a draft, then
  has it described, all in the background so nothing in the pipeline waits on it.

  It is opened as the ticket's owner, the same person its commits are by, and as
  the Rail app only when there is no owner or GitHub turns their token away. A
  failure is retried, and only the last attempt says so in the engineer's log.
  Oban's Lifeline rescues a job a restart left executing, so it is retried too.
  """
  use Oban.Worker,
    queue: :pull_requests,
    max_attempts: 3,
    unique: [keys: [:task_id], states: :incomplete, period: :infinity]

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.DraftBody

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Users.Schemas.User

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}} = job) do
    with %Task{cleaned_up_at: nil} = task <- Repo.get(Task, task_id),
         {:ok, task} <- task |> open() |> tag(:open),
         :ok <- task |> Pipeline.describe_pull_request() |> tag(:describe) do
      :ok
    else
      {{:error, reason}, step} -> fail(job, task_id, step, reason)
      _gone_or_cleaned_up -> :ok
    end
  end

  # The agent it waits on is stopped at 15 minutes.
  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: to_timeout(minute: 20)

  # A retry after the description failed finds the pull request already open.
  defp open(%Task{pr_number: number} = task) when is_integer(number), do: {:ok, task}

  defp open(%Task{} = task) do
    %Task{project: %Project{} = project} = task = Repo.preload(task, [:project, issue: :owner_user])

    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, %{"number" => number} = pull_request} <- find_or_create(token, task) do
      attrs = %{pr_number: number, pr_url: pull_request["html_url"], pr_is_draft: pull_request["draft"]}
      {:ok, task} = task |> Task.changeset(attrs) |> Repo.update()
      %Run{id: run_id} = engineer_run(task)
      # The task page refreshes on its runs' changes, which is how the Mark ready button appears.
      Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_changed, run_id})
      {:ok, broadcast_pipeline_changed(task)}
    end
  end

  defp find_or_create(token, %Task{project: %Project{} = project} = task) do
    case GitHub.find_pull_request(token, project.github_repo, task.worktree_name) do
      {:ok, nil} -> create(token, task)
      found -> found
    end
  end

  defp create(app_token, %Task{project: %Project{} = project, issue: %Issue{} = issue} = task) do
    attrs = %{
      title: "#{issue.identifier} #{issue.title}",
      head: task.worktree_name,
      base: project.default_branch,
      body: draft_body(issue),
      draft: true
    }

    with %User{github_token: owner_token} when is_binary(owner_token) <- issue.owner_user,
         {:ok, pull_request} <- GitHub.create_pull_request(owner_token, project.github_repo, attrs) do
      {:ok, pull_request}
    else
      _no_owner_or_refused -> GitHub.create_pull_request(app_token, project.github_repo, attrs)
    end
  end

  defp tag({:error, reason}, step), do: {{:error, reason}, step}
  defp tag(result, _step), do: result

  defp fail(%Oban.Job{attempt: attempt, max_attempts: max_attempts}, task_id, step, reason)
       when attempt >= max_attempts do
    what = if step == :open, do: "open the pull request", else: "write the pull request description"
    %Run{id: run_id} = engineer_run(Repo.get!(Task, task_id))
    Pipeline.append_run_events(run_id, nil, ["[rail] Could not #{what}: #{inspect(reason)}"])
    {:error, reason}
  end

  defp fail(%Oban.Job{}, _task_id, _step, reason), do: {:error, reason}

  defp engineer_run(%Task{} = task) do
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: task.project_id, stage: :engineer)
    Repo.get_by!(Run, task_id: task.id, role_id: role_id)
  end
end
