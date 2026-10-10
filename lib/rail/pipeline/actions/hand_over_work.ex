defmodule Rail.Pipeline.Actions.HandOverWork do
  @moduledoc """
  Sends on what the agent of the stage a task is at committed, through CI where the project has it and then
  pushed: the engineer's to Review, the Review lead's fixes or merge to its next round. A Fix finding the
  lead saved fixed is noted as fixed in the commit handed over.
  """

  import Rail.Pipeline.Utils.CiPassed
  import Rail.Pipeline.Utils.OpenPullRequest
  import Rail.Pipeline.Utils.ReviewPushedBranch
  import Rail.Pipeline.Utils.StartCi

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Sends on the commits on `run`'s branch that the remote does not have yet. Returns `{:ok, run}`, running
  while CI decides, or `{:error, reason}` when the run is not its stage's, there is nothing to send, or git,
  GitHub, CI or review refused. Safe to run again after a push that failed.
  """
  def hand_over_work(%Scope{} = scope, %Run{} = run) do
    %Run{task: %Task{project: %Project{ci_command: command}} = task} =
      run = Run |> Repo.get!(run.id) |> Repo.preload([:role, task: [:issue, :project]], force: true)

    with :ok <- handable(task, run) do
      review? = review?(task, run)
      # Set before CI starts, so a CI that finishes fast still finds it.
      flagged = update(run, %{review_on_ci_pass: review?})

      if command in [nil, ""] or ci_passed?(task),
        do: push(scope, flagged, review?),
        else: run_ci(flagged)
    end
  end

  # The branch is the current stage's: once Engineer hands it on, Review's lead commits it.
  defp handable(%Task{stage: stage} = task, %Run{role: %Role{stage: role_stage}}) do
    cond do
      Task.role_stage(stage) != role_stage -> {:error, {:invalid_stage, stage}}
      not Git.branch_unpushed?(task.worktree_path) -> {:error, :nothing_to_send}
      true -> :ok
    end
  end

  # A round is a read of a new HEAD, so a branch the last round already read is only pushed.
  defp review?(%Task{} = task, %Run{role: %Role{stage: :review_lead}}) do
    head = Git.branch_fingerprint(task.worktree_path)[:head_sha]
    note_fixes(task, head)

    case List.last(Pipeline.read_review(task)) do
      %{head: ^head} when is_binary(head) -> false
      _moved -> true
    end
  end

  defp review?(%Task{}, %Run{}), do: true

  defp note_fixes(%Task{} = task, head) do
    fixed = for %Finding{status: :fixed} = finding <- Pipeline.list_findings(task), pending?(finding), do: finding

    for finding <- fixed do
      notes = Enum.map(finding.notes, &in_commit(&1, head))

      finding
      |> Ecto.Changeset.change(fixed_in: head)
      |> Ecto.Changeset.put_embed(:notes, notes)
      |> Repo.update!()
    end

    if fixed != [], do: Pipeline.broadcast_output_saved(task)
  end

  # A fix the lead saved is in whatever commit the turn hands over, saved before the engineer committed or after.
  defp pending?(%Finding{notes: notes}), do: Enum.any?(notes, &match?(%FindingNote{kind: :fix, commit: nil}, &1))

  defp in_commit(%FindingNote{kind: :fix, commit: nil} = note, head), do: %{note | commit: head}
  defp in_commit(%FindingNote{} = note, _head), do: note

  # Pushed once CI has passed on HEAD, and reviewed once pushed when asked; CI's finish does both where it runs.
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
