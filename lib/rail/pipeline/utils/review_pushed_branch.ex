defmodule Rail.Pipeline.Utils.ReviewPushedBranch do
  @moduledoc """
  What a pushed commit asks for once it is up: the engineer's goes to Review, and a commit on the Review
  lead's run, its fixes or a merge of the default branch, starts the lead's next round.
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

    note = """
    The branch has moved since round #{round - 1}#{if head, do: ", to #{String.slice(head, 0, 7)},"} and #{after_what}. Run round #{round}: have the code reviewer read what changed since round #{round - 1} against the findings, and the explorers re-check the screens it touched. Save every finding not ruled Don't fix again with its status, raise anything new, and call `save_review`.
    """

    {:ok, briefed} =
      run
      |> Run.changeset(%{pending_answer: note, stage_outcome: :in_progress, error: nil})
      |> Repo.update()

    {:ok, role} = Roles.get_role(id: run.role_id)

    case Pipeline.start_review_run(%{briefed | task: task, role: role}) do
      {:ok, _os_process} -> :ok
      {:error, {:spawn_failed, reason, _run}} -> {:error, "Could not start round #{round}: #{inspect(reason)}"}
      {:error, :dispatch_disabled} -> {:error, "Dispatch is off, so round #{round} was not started."}
    end
  end
end
