defmodule Rail.Learnings.Actions.ApproveLearningProposal do
  @moduledoc """
  A person approving a proposal, claimed with a conditional update on `pending` so a second click or tab is told it was already decided.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.ApplyProposal
  import Rail.Learnings.Utils.BroadcastLearningsChanged

  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Approves and applies `proposal`. Returns `{:ok, proposal}` as it now stands, or
  `{:error, :already_decided}`.
  """
  def approve_learning_proposal(%Scope{} = scope, %LearningProposal{id: id, project_id: project_id}) do
    result =
      Repo.transaction(fn ->
        {claimed, _rows} =
          Repo.update_all(
            from(p in LearningProposal, where: p.id == ^id and p.project_id == ^project_id and p.status == :pending),
            set: [status: :approved, decided_by_id: scope.user && scope.user.id, decided_at: DateTime.utc_now()]
          )

        if claimed == 0, do: Repo.rollback(:already_decided)

        case apply_proposal(scope, Repo.get!(LearningProposal, id)) do
          {:ok, applied} -> applied
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, applied} <- result do
      broadcast_learnings_changed(project_id)
      {:ok, Repo.reload!(applied)}
    end
  end
end
