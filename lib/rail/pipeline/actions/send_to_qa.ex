defmodule Rail.Pipeline.Actions.SendToQa do
  @moduledoc """
  Hands a reviewed change to QA, once nothing is left outstanding on it.

  Nothing outstanding means one of three things and they are all the same thing:
  the reviewer found nothing, the engineer fixed everything it did find, or a
  human read the findings and dismissed them. Rail does not rank those - a
  finding somebody chose to live with is closed.

  A one-way door: the task leaves review, and a task no longer there has nothing
  left to send.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Sends `run`'s task to the QA stage.

  Returns `{:ok, run}`, the review run that was handed in, latched done.
  """
  def send_to_qa(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :runs]], force: true)

    with :ok <- sendable(run.task) do
      {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
      {:ok, _next} = Pipeline.enter_stage(run.task, :qa)

      {:ok, %{latched | task: run.task, role: run.role}}
    end
  end

  defp sendable(%Task{stage: stage}) when stage != :review, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      Enum.any?(Pipeline.list_review_findings(task), &ReviewFinding.outstanding?/1) -> {:error, :findings_outstanding}
      true -> :ok
    end
  end
end
