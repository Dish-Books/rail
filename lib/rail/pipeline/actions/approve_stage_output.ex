defmodule Rail.Pipeline.Actions.ApproveStageOutput do
  @moduledoc """
  A person approves the file a custom stage saved, which moves its task on to the next stage of its sequence, where
  a `StartEngineer` job committed with the move starts it with the file in its brief. Other people's unsent comments
  on the file are deleted, since the conversation they would go to closes; the approver's own wait to be sent first.

  Approving is a one-way door. The task row is locked while the run is latched and the next stage claimed, so a second
  click or a second tab waits on the lock, then finds the task moved on and is refused before anything starts twice.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.BroadcastPlanComments
  import Rail.Pipeline.Utils.CheckAnswered
  import Rail.Pipeline.Utils.CheckUnsent

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Approves the output the custom stage `run` saved as the scope's user. Returns `{:ok, run}`, latched done, or
  `{:error, reason}`: `:not_found`, `{:invalid_stage, stage}` once the task is at another stage, `:already_approved`,
  `:stage_running` while its agent works, `:no_output` before it saved its file, `{:unanswered_questions, count}`, or
  `{:unsent_comments, count}` while the scope's user has that many comments unsent.
  """
  def approve_stage_output(%Scope{} = scope, %Run{} = run) do
    result =
      Repo.transaction(fn ->
        task = Repo.one!(from t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE")
        task = Repo.preload(task, [:issue, runs: :role])
        run = Enum.find(task.runs, &(&1.id == run.id))

        with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
             :ok <- approvable(task, run),
             :ok <- check_answered(task),
             :ok <- check_unsent(scope, task) do
          authors = delete_unsent_comments(task)
          {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
          next = Issue.calculate_next_stage(task.issue, Task.current_stage(task))
          {:ok, moved} = Pipeline.enter_stage(task, next, start: false)
          # Committed with the move, so the start does not depend on the caller outliving it.
          {:ok, _job} = Oban.insert(StartEngineer.new(%{task_id: task.id, stage: Atom.to_string(moved.stage)}))
          {%{latched | task: moved, role: run.role}, moved, authors}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # enter_stage's own broadcast went out inside the transaction, before a page could read the move.
    with {:ok, {run, task, authors}} <- result do
      for user_id <- authors, do: broadcast_plan_comments(task.id, user_id)
      broadcast_pipeline_changed(task)
      {:ok, run}
    end
  end

  defp approvable(%Task{} = task, %Run{role: %Role{} = role} = run) do
    cond do
      task.stage != :custom or not Task.works_stage?(task, role) -> {:error, {:invalid_stage, task.stage}}
      run.stage_outcome == :done -> {:error, :already_approved}
      Run.running?(run) -> {:error, :stage_running}
      not Enum.any?(Pipeline.read_stage_outputs(task), &(&1.name == task.custom_stage)) -> {:error, :no_output}
      true -> :ok
    end
  end

  # Returns whose comments went, so only their tabs are told.
  defp delete_unsent_comments(%Task{id: task_id}) do
    {_deleted, authors} =
      Repo.delete_all(
        from(comment in PlanComment,
          where: comment.task_id == ^task_id and comment.status == :unsent,
          select: comment.user_id
        )
      )

    Enum.uniq(authors)
  end
end
