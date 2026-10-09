defmodule Rail.Pipeline.Actions.CommitWork do
  @moduledoc """
  Commits the worktree for whichever stage has the branch and sends it on, through CI where the project has
  it: the engineer's work to Review, the Review lead's fix round, noted on each finding, to its next round.
  """

  import Rail.Pipeline.Utils.CommitMessage
  import Rail.Pipeline.Utils.SendBranchOn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Commits the worktree on `run`, the run of the stage its task is at, under `attrs`' `:message`, or one
  saying it holds follow-up changes, and sends it on. At Review, `:fixes` and `:other_files` are what the
  round fixed, as `Rail.Pipeline.end_turn_and_commit/3` accepted them.

  Returns `{:ok, run}`, running while CI decides, or `{:error, reason}` when the run is not its stage's or
  git, GitHub, CI or review refused. Safe to run again after a push that failed: there is nothing left to
  commit and everything still to push.
  """
  def commit_work(%Scope{} = scope, %Run{} = run, attrs \\ %{}) when is_map(attrs) do
    %Run{task: %Task{} = task} = run = Run |> Repo.get!(run.id) |> Repo.preload([:role, task: [:issue, :project]])

    with :ok <- committable(task, run),
         {:ok, sha} <- commit(scope, task, run, attrs[:message]) do
      if sha && run.role.stage == :review_lead,
        do: record_fixes(task, run, fix_round(task), sha, attrs[:fixes] || [], attrs[:other_files] || [])

      send_branch_on(scope, run, true)
    end
  end

  # The branch is the current stage's: once Engineer hands it on, Review commits it.
  defp committable(%Task{stage: stage}, %Run{role: %Role{stage: role_stage}}) do
    if Task.role_stage(stage) == role_stage, do: :ok, else: {:error, {:invalid_stage, stage}}
  end

  defp commit(%Scope{} = scope, %Task{} = task, %Run{role: %Role{stage: stage}}, message) do
    step = if stage == :review_lead, do: "Fix round #{fix_round(task)}"

    if Git.worktree_dirty?(task.worktree_path),
      do: Git.commit_worktree(scope, task, commit_message(task, message, step)),
      else: {:ok, nil}
  end

  defp fix_round(%Task{} = task), do: max(length(Pipeline.read_review(task)), 1)

  defp record_fixes(%Task{} = task, %Run{} = run, round, sha, fixes, others) do
    now = DateTime.utc_now()

    for %{finding: finding, covered: covered, left: left, files: files, test: test} <- fixes do
      places =
        finding.places
        |> Enum.with_index(1)
        |> Enum.map(fn {place, n} ->
          case List.keyfind(left, n, 0) do
            {^n, reason} -> FindingPlace.leave_changeset(place, reason)
            nil -> place
          end
        end)

      # A finding from before places has none to name, so its note names none.
      note = %{
        round: round,
        kind: :fix,
        at: now,
        commit: sha,
        covered: for(n <- covered, %FindingPlace{} = place <- [place(finding, n)], do: FindingPlace.describe(place)),
        left:
          for(
            {n, reason} <- left,
            %FindingPlace{} = place <- [place(finding, n)],
            do: "#{FindingPlace.describe(place)}: #{reason}"
          ),
        files: files,
        test: "#{String.trim(test["file"])}: #{String.trim(test["name"])}"
      }

      finding
      |> Finding.note_changeset(%{status: :fixed, fixed_in: sha, note: note})
      |> Ecto.Changeset.put_embed(:places, places)
      |> Repo.update!()
    end

    lines =
      for %{"path" => path, "reason" => reason} <- others, do: "[rail] #{path} changed in fix round #{round}: #{reason}"

    if lines != [], do: Pipeline.append_run_events(run.id, nil, lines)
    Pipeline.broadcast_output_saved(task)
  end

  defp place(%Finding{places: places}, n), do: Enum.at(places, n - 1)
end
