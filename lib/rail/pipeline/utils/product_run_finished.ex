defmodule Rail.Pipeline.Utils.ProductRunFinished do
  @moduledoc """
  Where a finished product run leaves its task.

  The product agent's ticket stays in scratch until a human approves it: nothing
  is captured here and nothing moves. `approve_product_plan/2` is what publishes
  the ticket and enters the next stage.

  What a product run can get wrong is exiting cleanly without leaving a ticket,
  and that is recorded on the run rather than parking a human in front of an empty
  page, so the stage stays open for the message that fixes it. The agent stopping
  because the report did not survive contact with the code lands here too, which
  is right: the human is sent to read the conversation rather than left looking at
  nothing.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "Finishes `run` as the product stage."
  def product_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)

    case Pipeline.read_ticket(task) do
      %{} -> run
      nil -> fail(run, "The product agent did not write #{ticket_file(task)}.")
    end
  end

  defp ticket_file(%Task{issue: %Issue{identifier: identifier}}), do: "tickets/#{identifier}.md"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
