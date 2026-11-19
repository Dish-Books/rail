defmodule Rail.Pipeline.Actions.CheckLearnings do
  @moduledoc """
  Whether a task's learnings are addressed, which a tech lead's Approve and Merge wait for: no curator pass is
  queued, its curator finished its turn without failing, and every proposal it made has an Approve or Reject
  chosen, which the merge then carries out.
  """

  import Ecto.Query

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartCurator
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Returns `:ok`, or `{:error, reason}`: `:curator_running` while a pass is queued or the curator works,
  `:curator_failed`, or `{:learnings_open, count}` with the number of the task's proposals nobody chose for yet.
  """
  def check_learnings(%Task{id: task_id, project_id: project_id}) do
    task = Task |> Repo.get!(task_id) |> Repo.preload(runs: :role)
    curator = Enum.find(task.runs, &match?(%Run{role: %Role{stage: :curator}}, &1))

    cond do
      queued?(task_id) and curator?(project_id) -> {:error, :curator_running}
      curator == nil -> :ok
      Run.running?(curator) -> {:error, :curator_running}
      Run.state(curator) == :failed -> {:error, :curator_failed}
      true -> open(task_id, project_id)
    end
  end

  # Between the mark and the job starting the curator, the pass is still to come.
  defp queued?(task_id) do
    worker = inspect(StartCurator)

    Repo.exists?(
      from j in Oban.Job,
        where: j.worker == ^worker and j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("?->>'task_id' = ?", j.args, ^task_id)
    )
  end

  # A project with no curator role starts nothing, and the job finishing that way tells no open page.
  defp curator?(project_id), do: Repo.exists?(from r in Role, where: r.project_id == ^project_id and r.stage == :curator)

  defp open(task_id, project_id) do
    proposals = Learnings.list_learning_proposals(task_id: task_id, project_id: project_id)

    case Enum.count(proposals, &LearningProposal.undecided?/1) do
      0 -> :ok
      count -> {:error, {:learnings_open, count}}
    end
  end
end
