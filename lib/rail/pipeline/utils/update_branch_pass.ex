defmodule Rail.Pipeline.Utils.UpdateBranchPass do
  @moduledoc """
  One pass of merging the default branch into a task's branch: Rail merges, or
  carries on the merge already under way, and what comes of it decides what next.

  Going through cleanly sends the branch on as any finished round is, through CI
  or pushed. Stopping on conflicts hands them to the engineer, who resolves and
  stages them and nothing more, so that Rail's `--continue` signs the merge.
  Each pass says in the engineer's log what it did and what it asked for.
  A merge that brings anything in sends a task past Engineer back there.
  """

  import Rail.Pipeline.Utils.ReturnToEngineer

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @doc """
  Runs a merge pass on the engineer's `run`. Returns `{:ok, run}` as the pass left
  it, or `{:error, reason}`.
  """
  def update_branch_pass(%Scope{} = scope, %Run{task: %Task{} = task} = run) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)
    head_sha = Git.branch_fingerprint(task.worktree_path)[:head_sha]

    case Git.merge_default_branch(scope, task) do
      :ok ->
        say(run, "Merged origin/#{base} in.")

        # A branch already up to date keeps its HEAD, and has nothing new to review.
        {:ok, task} =
          if match?(%{head_sha: ^head_sha}, Git.branch_fingerprint(task.worktree_path)),
            do: {:ok, task},
            else: return_to_engineer(task)

        send_on(%{run | task: task})

      {:conflicts, files} ->
        say(
          run,
          "Merging origin/#{base} in stopped on conflicts in #{Enum.join(files, ", ")}. Asked the engineer to resolve them."
        )

        {:ok, task} = return_to_engineer(task)
        resolve(%{run | task: task}, base, files)

      {:error, reason} ->
        say(run, "Merging origin/#{base} in failed.")
        {:error, reason}
    end
  end

  defp say(%Run{id: run_id}, line), do: Pipeline.append_run_events(run_id, nil, ["[rail] #{line}"])

  defp send_on(%Run{task: %Task{} = task} = run) do
    {:ok, task} = task |> Task.changeset(%{is_updating_branch: false}) |> Repo.update()

    # CI that fails sends the engineer a round to fix, so the stage is open again.
    {:ok, open} = run |> Run.changeset(%{stage_outcome: :in_progress, ci_failure_streak: 0}) |> Repo.update()

    with :ok <- Pipeline.commit_engineer_work(Scope.for_system(), task, nil) do
      # Starting CI moved the run on, even into the line; with no CI, the push was the whole of it.
      %Run{} = sent = Repo.get!(Run, open.id)

      attrs =
        if sent.status in [:running, :waiting_for_resources, :waiting_for_usage], do: %{}, else: %{stage_outcome: :done}

      {:ok, sent} = sent |> Run.changeset(attrs) |> Repo.update()
      {:ok, %{sent | task: task, role: run.role}}
    end
  end

  defp resolve(%Run{task: %Task{} = task} = run, base, files) do
    {:ok, task} = task |> Task.changeset(%{is_updating_branch: true}) |> Repo.update()
    attrs = %{pending_answer: brief(base, files), status: :running, error: nil, exit_code: nil}
    {:ok, briefed} = run |> Run.changeset(attrs) |> Repo.update()
    # Each turn's system prompt is the one it is spawned with, so it is read as the repo has it now.
    {:ok, role} = Roles.get_role(id: run.role_id)

    case Pipeline.start_engineer_run(%{briefed | task: task, role: role}) do
      {:ok, os_process} -> {:ok, os_process.run}
      {:error, {:spawn_failed, _reason, %Run{} = failed}} -> {:error, failed.error}
      {:error, :dispatch_disabled} -> {:error, :dispatch_disabled}
    end
  end

  defp brief(base, files) do
    """
    Rail merged origin/#{base} into this branch, and it stopped on conflicts in:

    #{Enum.map_join(files, "\n", &"- #{&1}")}

    Each conflict shows the branch's side, what the file was before either side changed it, and origin/#{base}'s side. `git log origin/#{base}..HEAD` shows what this branch set out to do, and `git log HEAD..origin/#{base}` what landed on #{base} since. Resolve each the way both sides meant it, then `git add` it. That is the only git you run: no commit, no `git merge --continue` or `--abort`. Rail commits the merge once you stop.
    """
  end
end
