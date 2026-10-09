defmodule Rail.Pipeline.Actions.EndTurnAndCommit do
  @moduledoc """
  The engineer's `commit`: ends the turn it is called in, then commits the worktree
  under the agent's message and sends it on, pushed or through CI, to Review once it passes.
  """

  import Rail.Pipeline.Utils.EndTurn
  import Rail.Pipeline.Utils.WithLiveTurn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Ends `task`'s engineer turn, carried by `os_process`, and commits under
  `message`: `{:ok, :committing}` once the turn is stopped, or `{:refused, text}`
  while it is still going or once it has already ended.
  """
  def end_turn_and_commit(%Task{} = task, %OsProcess{} = os_process, message) do
    case with_live_turn(os_process, fn -> accept(Repo.reload!(task), Repo.get!(Run, os_process.run_id), message) end) do
      :ended ->
        {:refused, "Refused, nothing committed again. This turn has already ended and handed its work to Rail."}

      result ->
        result
    end
  end

  defp accept(%Task{} = task, %Run{} = run, message) do
    cond do
      not is_binary(message) or String.trim(message) == "" ->
        {:refused,
         "Refused, nothing committed. message: is required, one line saying what this change does and then the body."}

      task.stage != :engineer ->
        {:refused,
         "Refused, nothing committed. The task is at #{Task.stage_label(task.stage)}, past Engineer, so your work " <>
           "is no longer committed from this conversation."}

      task.is_updating_branch ->
        {:refused,
         "Refused, nothing committed. This turn is resolving a merge, and Rail commits the merge itself once you stop: " <>
           "`git add` each resolved file and end your turn without calling commit."}

      not Git.worktree_dirty?(task.worktree_path) and run.ci_failure_streak == 0 ->
        {:refused,
         "Refused, nothing committed. Nothing in the worktree has changed. Make the change first, or say in your " <>
           "last message why there is nothing to do."}

      true ->
        :ok = end_turn(run, fn -> commit(run, message) end)
        {:ok, :committing}
    end
  end

  # After a CI failure, committing nothing is the engineer asking for CI again.
  defp commit(%Run{} = run, message) do
    case Pipeline.commit_and_send_to_review(Scope.for_system(), run, String.trim(message)) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, "Could not commit the engineer's work: #{describe(reason)}"}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
