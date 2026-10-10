defmodule Rail.Pipeline.Actions.HandOverWork do
  @moduledoc """
  Sends on what the agent of the stage a task is at committed, through CI where the project has it and then
  pushed: the engineer's to Review, the Review lead's fixes or merge to its next round. A Fix finding the
  lead saved fixed is noted as fixed in the commit handed over.
  """

  import Rail.Pipeline.Utils.SendBranchOn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Sends on the commits on `run`'s branch that the remote does not have yet. Returns `{:ok, run}`, running
  while CI decides, or `{:error, reason}` when the run is not its stage's, there is nothing to send, or git,
  GitHub, CI or review refused. Safe to run again after a push that failed.
  """
  def hand_over_work(%Scope{} = scope, %Run{} = run) do
    %Run{task: %Task{} = task} =
      run = Run |> Repo.get!(run.id) |> Repo.preload([:role, task: [:issue, :project]], force: true)

    with :ok <- handable(task, run) do
      send_branch_on(scope, run, review?(task, run))
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
end
