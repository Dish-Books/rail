defmodule Rail.Learnings.Actions.ChooseTaskProposal do
  @moduledoc """
  A person's Approve or Reject of a task's proposal, which they can change until the task merges: the proposal stays
  pending with their choice, and the merge approves or rejects it. Once the task has merged, a choice decides at once.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Chooses `choice`, `:approved` or `:rejected`, for `proposal`. Returns `{:ok, proposal}` as it now stands, or
  `{:error, reason}`: `:already_decided` once it was approved or rejected, `:not_found` for a proposal with no task, or
  what deciding it gave once its task merged.
  """
  def choose_task_proposal(%Scope{} = scope, %LearningProposal{id: id, project_id: project_id}, choice)
      when choice in [:approved, :rejected] do
    # One statement, so a merge that lands first leaves it for the merge to decide, and one after sees this choice.
    {chosen, _rows} =
      Repo.update_all(
        from(p in LearningProposal,
          join: t in Task,
          on: t.id == p.task_id,
          where: p.id == ^id and p.project_id == ^project_id and p.status == :pending and is_nil(t.merged_at)
        ),
        set: [choice: choice, decided_by_id: scope.user && scope.user.id, decided_at: DateTime.utc_now()]
      )

    if chosen == 1 do
      broadcast_learnings_changed(project_id)
      {:ok, Repo.get!(LearningProposal, id)}
    else
      unchosen(scope, id, project_id, choice)
    end
  end

  defp unchosen(scope, id, project_id, choice) do
    case Repo.one(from p in LearningProposal, where: p.id == ^id and p.project_id == ^project_id, preload: :task) do
      %LearningProposal{status: :pending, task: %Task{merged_at: %DateTime{}}} = proposal ->
        decide(scope, proposal, choice)

      %LearningProposal{status: :pending} ->
        {:error, :not_found}

      %LearningProposal{} ->
        {:error, :already_decided}

      nil ->
        {:error, :not_found}
    end
  end

  defp decide(scope, proposal, :approved), do: Learnings.approve_learning_proposal(scope, proposal)
  defp decide(scope, proposal, :rejected), do: Learnings.reject_learning_proposal(scope, proposal)
end
