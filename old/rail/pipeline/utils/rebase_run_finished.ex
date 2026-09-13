defmodule Rail.Pipeline.Utils.RebaseRunFinished do
  @moduledoc """
  Where a finished rebase run leaves its task.

  A rebase is the engineer role on a detour: the task never left the stage it was
  parked at, so finishing one clears the detour and nothing else. It settles apart
  from the stages because the engineer run it borrows is usually already latched
  `:done` from the work it did before the branch ever conflicted.

  A rebase changes whether the branch merges, so the answer Rail is holding for
  that is stale the moment one lands.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc "Finishes `run` as a rebase detour."
  def rebase_run_finished(%Run{exit_code: 0, task: %Task{} = task} = run, opts) do
    {:ok, task} = task |> Task.changeset(%{is_rebasing: false}) |> Repo.update()
    Pipeline.refresh_mergeability(task, opts)
    %{run | task: task}
  end

  def rebase_run_finished(%Run{} = run, _opts), do: run
end
