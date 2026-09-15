defmodule Rail.Pipeline.Utils.EngineerRunFinished do
  @moduledoc """
  Where a finished engineer run leaves its task.

  The engineer produces no artifact a human reads at a glance, so what it leaves
  is the worktree, and the commit message it wrote is its word that the worktree
  is finished. That word is what this acts on: commit the tree, push the branch,
  and stop. Nothing moves — a human reads the diff and sends it to review.

  What an engineer run can get wrong is exiting cleanly having written no
  message, or having changed nothing at all, and both are recorded on the run so
  the stage stays open for the message that fixes it.
  """

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc "Finishes `run` as the engineer stage."
  def engineer_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)

    cond do
      Pipeline.read_commit_message(task) == nil ->
        fail(run, "The engineer did not write #{message_file(task)}.")

      not Git.worktree_dirty?(task.worktree_path) ->
        fail(run, "The engineer said it was done but changed nothing in the worktree.")

      true ->
        commit(run, task)
    end
  end

  defp commit(%Run{} = run, %Task{} = task) do
    case Pipeline.commit_engineer_work(Scope.for_system(), task) do
      {:ok, _sha} -> run
      {:error, reason} -> fail(run, "Could not commit the engineer's work: #{describe(reason)}")
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp message_file(%Task{issue: %Issue{identifier: identifier}}), do: "commits/#{identifier}.md"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
