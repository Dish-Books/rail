defmodule Rail.Learnings.Workers.IssueFinished do
  @moduledoc """
  What a finished issue means for the knowledge base: a rule promoted into it retires once it is done, and its task is distilled once.
  """
  use Oban.Worker,
    queue: :learnings,
    max_attempts: 3,
    unique: [keys: [:issue_id], states: :incomplete]

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id}}) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue ->
        retire_promoted(issue)
        extract(issue)

      nil ->
        :ok
    end
  end

  defp retire_promoted(%Issue{state: :done, id: issue_id}) do
    from(p in LearningProposal,
      where: p.issue_id == ^issue_id and p.action == :promote and p.status == :approved,
      preload: :learning
    )
    |> Repo.all()
    |> Enum.each(&Learnings.retire_learning(Scope.for_system(), &1.learning))
  end

  defp retire_promoted(%Issue{}), do: :ok

  defp extract(%Issue{id: issue_id}) do
    case Pipeline.list_tasks(issue_id: issue_id, include_cleaned_up: true, order_by: [desc: :inserted_at]) do
      [task | _earlier] ->
        case Learnings.extract_task_learnings(task) do
          {:ok, _task} -> :ok
          {:error, {:waiting_for_usage, resets_at}} -> {:snooze, max(DateTime.diff(resets_at, DateTime.utc_now()), 1)}
          {:error, reason} -> {:error, reason}
        end

      [] ->
        :ok
    end
  end
end
