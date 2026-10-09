defmodule Rail.Pipeline.Utils.UpdateBranchPass do
  @moduledoc """
  One pass of merging the default branch in on the current stage's run: a clean merge is sent on, at Review
  to a next round, and conflicts go to that run's agent to stage for Rail's `--continue`. Nothing goes back.
  """

  import Rail.Pipeline.Utils.SendBranchOn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Runs a merge pass on `run`, the engineer's or the Review lead's. Returns `{:ok, run}` as the pass left
  it, or `{:error, reason}`.
  """
  def update_branch_pass(%Scope{} = scope, %Run{task: %Task{} = task} = run) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)
    head_sha = Git.branch_fingerprint(task.worktree_path)[:head_sha]

    case Git.merge_default_branch(scope, task) do
      :ok ->
        say(run, "Merged origin/#{base} in.")
        {:ok, task} = task |> Task.changeset(%{is_updating_branch: false}) |> Repo.update()
        moved? = not match?(%{head_sha: ^head_sha}, Git.branch_fingerprint(task.worktree_path))
        send_on(scope, %{run | task: task}, moved?)

      {:conflicts, files} ->
        say(
          run,
          "Merging origin/#{base} in stopped on conflicts in #{Enum.join(files, ", ")}. Asked the #{agent(run)} to resolve them."
        )

        resolve(run, base, files)

      {:error, reason} ->
        say(run, "Merging origin/#{base} in failed.")
        {:error, reason}
    end
  end

  defp say(%Run{id: run_id}, line), do: Pipeline.append_run_events(run_id, nil, ["[rail] #{line}"])

  # A branch already up to date at Review has nothing new for a round to read.
  defp send_on(%Scope{}, %Run{role: %Role{stage: :review_lead}} = run, false), do: {:ok, run}

  defp send_on(%Scope{} = scope, %Run{role: %Role{stage: stage}} = run, _moved?) do
    # CI that fails sends the agent a round to fix, so the stage is open again.
    {:ok, open} = run |> Run.changeset(%{stage_outcome: :in_progress, ci_failure_streak: 0}) |> Repo.update()

    with {:ok, sent} <- send_branch_on(scope, open, stage == :review_lead) do
      # Starting CI or a round moved the run on; at Engineer with no CI, the push was the whole of it.
      attrs = if Run.running?(sent) or stage == :review_lead, do: %{}, else: %{stage_outcome: :done}
      {:ok, sent} = sent |> Run.changeset(attrs) |> Repo.update()
      {:ok, %{sent | task: run.task, role: run.role}}
    end
  end

  defp resolve(%Run{task: %Task{} = task} = run, base, files) do
    {:ok, task} = task |> Task.changeset(%{is_updating_branch: true}) |> Repo.update()
    attrs = %{pending_answer: brief(run, base, files), status: :running, error: nil, exit_code: nil}
    {:ok, briefed} = run |> Run.changeset(attrs) |> Repo.update()
    # Each turn's system prompt is the one it is spawned with, so it is read as the repo has it now.
    {:ok, role} = Roles.get_role(id: run.role_id)

    case start(%{briefed | task: task, role: role}) do
      {:ok, os_process} -> {:ok, os_process.run}
      {:error, {:spawn_failed, _reason, %Run{} = failed}} -> {:error, failed.error}
      {:error, :dispatch_disabled} -> {:error, :dispatch_disabled}
    end
  end

  defp start(%Run{role: %Role{stage: :review_lead}} = run), do: Pipeline.start_review_run(run)
  defp start(%Run{} = run), do: Pipeline.start_engineer_run(run)

  defp agent(%Run{role: %Role{stage: :review_lead}}), do: "Review lead"
  defp agent(%Run{}), do: "engineer"

  defp brief(%Run{} = run, base, files) do
    """
    Rail merged origin/#{base} into this branch, and it stopped on conflicts in:

    #{Enum.map_join(files, "\n", &"- #{&1}")}

    #{who(run)}Each conflict shows the branch's side, what the file was before either side changed it, and origin/#{base}'s side. `git log origin/#{base}..HEAD` shows what this branch set out to do, and `git log HEAD..origin/#{base}` what landed on #{base} since. Resolve each the way both sides meant it, then `git add` it. That is the only git you run: no commit, no `git merge --continue` or `--abort`, and no `commit` tool. Rail commits the merge once you stop.
    """
  end

  defp who(%Run{role: %Role{stage: :review_lead}}),
    do: "Hand them to the engineer, with what follows, and end your turn once it has staged every one. "

  defp who(%Run{}), do: ""
end
