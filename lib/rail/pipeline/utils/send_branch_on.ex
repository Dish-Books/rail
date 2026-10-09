defmodule Rail.Pipeline.Utils.SendBranchOn do
  @moduledoc """
  Sends a branch on from the run that moved it: through CI on that run where CI has not passed on HEAD,
  pushed otherwise, and reviewed once pushed when asked, by CI's finish where CI runs.
  """

  import Rail.Pipeline.Utils.CiPassed
  import Rail.Pipeline.Utils.OpenPullRequest
  import Rail.Pipeline.Utils.ReviewPushedBranch
  import Rail.Pipeline.Utils.StartCi

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sends `run`'s branch on, then reviews it when `review?`. Returns `{:ok, run}`, running while CI decides,
  or `{:error, reason}` when git, GitHub, CI or review refused.
  """
  def send_branch_on(%Scope{} = scope, %Run{} = run, review?) when is_boolean(review?) do
    %Run{task: %Task{project: %Project{ci_command: command}} = task} =
      run = Run |> Repo.get!(run.id) |> Repo.preload([:role, task: [:issue, :project]], force: true)

    # Set before CI starts, so a CI that finishes fast still finds it.
    flagged = update(run, %{review_on_ci_pass: review?})

    if command in [nil, ""] or ci_passed?(task),
      do: push(scope, flagged, review?),
      else: run_ci(flagged)
  end

  defp push(%Scope{} = scope, %Run{task: %Task{} = task} = run, review?) do
    case Git.push_branch(scope, task) do
      :ok ->
        pushed = %{update(run, %{review_on_ci_pass: false, error: nil}) | task: open_pull_request(task, run)}
        if review?, do: review_pushed_branch(pushed, "it was pushed"), else: {:ok, pushed}

      {:error, reason} ->
        _cleared = update(run, %{review_on_ci_pass: false})
        {:error, reason}
    end
  end

  defp run_ci(%Run{} = run) do
    case start_ci(run) do
      {:ok, _os_process} ->
        {:ok, %{Repo.get!(Run, run.id) | task: run.task, role: run.role}}

      {:error, %Run{error: error} = failed} ->
        _cleared = update(failed, %{review_on_ci_pass: false})
        {:error, error}
    end
  end

  defp update(%Run{} = run, attrs) do
    {:ok, updated} = run |> Run.changeset(attrs) |> Repo.update()
    %{updated | task: run.task, role: run.role}
  end
end
