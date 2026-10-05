defmodule Rail.Learnings.Actions.RejectLearningProposal do
  @moduledoc """
  A person turning a proposal down, which for an override is keeping the rule. A rejected draft stays `proposed` as the record.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged

  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Rejects `proposal`. Returns `{:ok, proposal}` as it now stands, or `{:error, :already_decided}`.
  """
  def reject_learning_proposal(%Scope{} = scope, %LearningProposal{id: id, project_id: project_id}) do
    {claimed, _rows} =
      Repo.update_all(
        from(p in LearningProposal, where: p.id == ^id and p.project_id == ^project_id and p.status == :pending),
        set: [status: :rejected, decided_by_id: scope.user && scope.user.id, decided_at: DateTime.utc_now()]
      )

    if claimed == 1 do
      broadcast_learnings_changed(project_id)
      {:ok, Repo.get!(LearningProposal, id)}
    else
      {:error, :already_decided}
    end
  end
end
