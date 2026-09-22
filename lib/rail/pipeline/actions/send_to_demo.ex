defmodule Rail.Pipeline.Actions.SendToDemo do
  @moduledoc """
  Sends a task that has been through QA on to the demo stage.

  Only with nothing left: everything QA raised has been ruled on, and nothing
  ruled `fix` is still outstanding. A pass that found nothing and a pass whose
  findings were all dismissed are the same thing here, which is the point - the
  human decides what QA's verdict is worth, and the verdict itself gates
  nothing.

  This is a one-way door, and it only opens it: whether the change needs a demo
  at all is the human's call, made on the demo tab.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Sends `run`'s task to the demo stage.

  Returns `{:ok, run}`, the QA run that was handed in, latched done.
  """
  def send_to_demo(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :runs]], force: true)

    with :ok <- sendable(run.task) do
      {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
      {:ok, _task} = Pipeline.enter_stage(run.task, :demo, start: false)

      {:ok, %{latched | task: run.task, role: run.role}}
    end
  end

  defp findings(%Task{} = task), do: Pipeline.list_qa_findings(task)

  defp sendable(%Task{stage: stage}) when stage != :qa, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      Enum.any?(findings(task), &QaFinding.undecided?/1) -> {:error, :findings_undecided}
      Enum.any?(findings(task), &QaFinding.outstanding?/1) -> {:error, :findings_outstanding}
      true -> :ok
    end
  end
end
