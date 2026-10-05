defmodule Rail.Pipeline.Actions.EndTurnAndCommit do
  @moduledoc """
  The engineer's `commit`: ends the turn it is called in, then commits the worktree
  under the agent's message and sends it on, pushed or through CI.
  """

  import Rail.Pipeline.Utils.EndEngineerTurn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Ends `task`'s engineer turn and commits under `message`: `{:ok, :committing}`
  once the turn is stopped, or `{:refused, text}` while it is still going.
  """
  def end_turn_and_commit(%Task{} = task, message) do
    task = Repo.reload!(task)

    cond do
      not is_binary(message) or String.trim(message) == "" ->
        {:refused,
         "Refused, nothing committed. message: is required, one line saying what this change does and then the body."}

      task.is_updating_branch ->
        {:refused,
         "Refused, nothing committed. This turn is resolving a merge, and Rail commits the merge itself once you stop: " <>
           "`git add` each resolved file and end your turn without calling commit."}

      not Git.worktree_dirty?(task.worktree_path) and not ci_failed?(task) ->
        {:refused,
         "Refused, nothing committed. Nothing in the worktree has changed. Make the change first, or say in your " <>
           "last message why there is nothing to do."}

      true ->
        :ok = end_engineer_turn(task, fn -> commit(task, message) end)
        {:ok, :committing}
    end
  end

  defp commit(%Task{} = task, message) do
    case Pipeline.commit_engineer_work(Scope.for_system(), task, String.trim(message)) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not commit the engineer's work: #{describe(reason)}"}
    end
  end

  # After a CI failure, committing nothing is the engineer asking for CI again.
  defp ci_failed?(%Task{} = task) do
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: task.project_id, stage: :engineer)
    match?(%Run{ci_failure_streak: streak} when streak > 0, Repo.get_by(Run, task_id: task.id, role_id: role_id))
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
