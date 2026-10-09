defmodule Rail.Pipeline.Utils.ReviewPushedBranch do
  @moduledoc """
  What a pushed commit asks for once it is up: the engineer's goes to Review, and a commit on the Review
  lead's run, its fixes or a merge of the default branch, starts the lead's next round. A merge is followed
  through first: the lead has main's changes read and the branch updated to them before the round.
  """

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Reviews `run`'s pushed branch, saying in a next round's conversation that it started `after_what`.
  Returns `{:ok, run}` as it now stands, or `{:error, reason}`.
  """
  def review_pushed_branch(%Run{role: %Role{stage: :review_lead}} = run, after_what) do
    with :ok <- start_next_round(run, after_what) do
      {:ok, %{Repo.get!(Run, run.id) | task: run.task, role: run.role}}
    end
  end

  def review_pushed_branch(%Run{} = run, _after_what), do: Pipeline.send_to_review(run)

  defp start_next_round(%Run{} = run, after_what) do
    %Run{task: %Task{} = task} = run = Repo.preload(run, [task: :issue], force: true)
    round = length(Pipeline.read_review(task)) + 1
    head = (Git.branch_fingerprint(task.worktree_path) || %{})[:head_sha]

    Pipeline.append_run_events(run.id, nil, ["[rail] Round #{round} started after #{after_what}"])

    note =
      case Git.load_branch_history(task) do
        %{commits: [%{merge?: true} = merge | _earlier], base: base} -> follow_through(merge, base, round, after_what)
        %{} -> round_note(round, head, after_what)
      end

    {:ok, briefed} =
      run
      |> Run.changeset(%{pending_answer: note, status: :running, stage_outcome: :in_progress, error: nil})
      |> Repo.update()

    {:ok, role} = Roles.get_role(id: run.role_id)

    case Pipeline.start_review_run(%{briefed | task: task, role: role}) do
      {:ok, _os_process} -> :ok
      {:error, {:spawn_failed, reason, _run}} -> {:error, "Could not start round #{round}: #{inspect(reason)}"}
      {:error, :dispatch_disabled} -> unstarted(briefed, "Dispatch is off, so round #{round} was not started.")
    end
  end

  defp round_note(round, head, after_what) do
    """
    The branch has moved since round #{round - 1}#{if head, do: ", to #{String.slice(head, 0, 7)},"} and #{after_what}. Run round #{round}: have the code reviewer read what changed since round #{round - 1} against the findings, and the explorers re-check the screens it touched. Save every finding not ruled Don't fix again with its status, raise anything new, and call `save_review`.
    """
  end

  # A merge that went through can still leave the branch calling what main renamed or testing what it changed.
  defp follow_through(%{short_sha: sha, conflicts: conflicts}, base, round, after_what) do
    resolved = if conflicts > 0, do: ", resolving #{conflicts} conflict#{if conflicts > 1, do: "s"},"

    """
    Rail merged origin/#{base} into the branch as #{sha}#{resolved} and #{after_what}. Follow main's changes through before round #{round}: have the code reviewer read what the merge brought in with `git diff #{sha}^1 #{sha}` against the functions, statuses, fields, config and tests this branch relies on or adds, and grep the whole merged tree, not only the branch's own files, for each status, flag, field and relation the branch adds. Have the engineer update the branch's code, tests and comments to match, then call `commit` with `merge_follow_up` set, a commit `message`, no `findings`, and every changed file in `other_files` with why: Rail commits it as a Merge follow-up and starts round #{round} once CI passes. When nothing needs changing, say so in one line and run round #{round} now: have the code reviewer read what changed since round #{round - 1} against the findings, and the explorers re-check the screens it touched. Save every finding not ruled Don't fix again with its status, raise anything new, and call `save_review`.
    """
  end

  # Marked running before the spawn so the page shows the round, it goes back when nothing was spawned.
  defp unstarted(%Run{} = run, text) do
    {:ok, _settled} = run |> Run.changeset(%{status: :finished}) |> Repo.update()
    {:error, text}
  end
end
