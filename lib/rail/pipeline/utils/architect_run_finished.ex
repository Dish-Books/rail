defmodule Rail.Pipeline.Utils.ArchitectRunFinished do
  @moduledoc """
  Where a finished architect run leaves its task.

  The architect's plan stays in scratch until a human approves it: nothing is
  captured here and nothing moves. What an architect run can get wrong is exiting
  cleanly without leaving a plan, and that is recorded on the run rather than
  parking a human in front of nothing, so the stage stays open for the message
  that fixes it.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "Finishes `run` as the architect stage."
  def architect_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)

    case Pipeline.read_plan(task) do
      content when is_binary(content) -> run
      nil -> fail(run, "The architect did not write #{plan_file(task)}.")
    end
  end

  defp plan_file(%Task{issue: %Issue{identifier: identifier}}), do: "plans/#{identifier}.md"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
