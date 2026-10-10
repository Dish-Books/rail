defmodule Rail.Pipeline.Utils.EngineerRunFinished do
  @moduledoc """
  Where a finished engineer turn leaves its task.

  The engineer commits its own work, and a turn that ends with commits the remote has not had is the work
  handed over: Rail sends it through CI where the project has it, pushes it, and sends it to Review. A turn
  that committed nothing new, such as one answering a message, leaves the stage open for the turn that does.
  """

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc "Finishes `run` as the engineer stage: the run as it now stands, or `{:open, run}` with nothing sent."
  def engineer_run_finished(%Run{task: %Task{} = task} = run, _opts) do
    if Task.worktree_present?(task) and Git.branch_unpushed?(task.worktree_path) do
      case Pipeline.hand_over_work(Scope.for_system(), run) do
        {:ok, %Run{} = sent} -> %{sent | task: run.task, role: run.role}
        {:error, reason} -> fail(run, "The engineer's commits could not be sent on: #{describe(reason)}")
      end
    else
      {:open, run}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
