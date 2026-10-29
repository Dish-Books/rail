defmodule Rail.Pipeline.Utils.EngineerRunFinished do
  @moduledoc """
  Where a finished engineer turn leaves its task.

  The engineer commits its own work, and a turn that ends with commits the remote has not had is the work
  handed over: Rail sends it through CI where the project has it, pushes it, and sends it on to the next stage. A later
  round whose plan changes no code, such as one that only retakes the screens, has nothing to commit, so a turn
  that leaves it clean and pushed sends it to Review as a CI pass does, running CI first where HEAD has not
  passed it. In the first round a turn that committed nothing, such as one answering a message, leaves the stage
  open for the turn that does, as does work left uncommitted. A branch Rail will not push, rewritten or pushed
  to outside Rail, goes back to the engineer to merge.
  """

  import Rail.Pipeline.Utils.SendBackRefusedPush
  import Rail.Pipeline.Utils.StartCi

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc "Finishes `run` as the engineer stage: the run as it now stands, or `{:open, run}` with nothing sent."
  def engineer_run_finished(%Run{task: %Task{} = task} = run, _opts) do
    cond do
      not Task.worktree_present?(task) -> {:open, run}
      Git.branch_unpushed?(task.worktree_path) -> hand_over(run)
      # A queued message is the engineer about to work again, so the round is not over yet.
      is_binary(run.pending_chat) or Git.worktree_dirty?(task.worktree_path) -> {:open, run}
      match?(%Round{number: number} when number > 1, Pipeline.read_plan(task)) -> send_as_it_stands(run)
      true -> {:open, run}
    end
  end

  defp hand_over(%Run{} = run) do
    case Pipeline.hand_over_work(Scope.for_system(), run) do
      {:ok, %Run{} = sent} ->
        %{sent | task: run.task, role: run.role}

      {:error, reason} when reason in [:history_rewritten, :pushed_outside_rail] ->
        send_back_refused_push(run, reason)

      {:error, reason} ->
        fail(run, "The engineer's commits could not be sent on: #{describe(reason)}")
    end
  end

  defp send_as_it_stands(%Run{} = run) do
    case Pipeline.send_to_next_stage(run) do
      {:ok, %Run{} = sent} ->
        %{sent | task: run.task, role: run.role}

      {:error, :ci_not_passed} ->
        Pipeline.append_run_events(run.id, nil, [
          "[rail] The round committed nothing new, and CI has not passed on HEAD, so CI runs on it before Review."
        ])

        run_ci(run)

      {:error, reason} ->
        fail(run, "The round committed nothing new, but it was not sent to review: #{describe(reason)}")
    end
  end

  # Flagged before CI starts, so a CI that finishes fast still sends the round on.
  defp run_ci(%Run{} = run) do
    {:ok, flagged} = run |> Run.changeset(%{review_on_ci_pass: true}) |> Repo.update()

    case start_ci(flagged) do
      {:ok, _os_process} ->
        %{Repo.get!(Run, run.id) | task: run.task, role: run.role}

      {:error, %Run{} = failed} ->
        {:ok, cleared} = failed |> Run.changeset(%{review_on_ci_pass: false}) |> Repo.update()
        %{cleared | task: run.task, role: run.role}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
