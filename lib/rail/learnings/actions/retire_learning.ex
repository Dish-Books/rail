defmodule Rail.Learnings.Actions.RetireLearning do
  @moduledoc """
  Retires a rule and rejects every proposal still pending on it, so none can bring
  it back. A rule already retired is returned as it is, so a second tab succeeds too.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Retires `learning`. Returns `{:ok, learning}` as it now stands.
  """
  def retire_learning(%Scope{} = scope, %Learning{id: id, project_id: project_id}) do
    now = DateTime.utc_now()

    {:ok, retired} =
      Repo.transaction(fn ->
        Repo.update_all(
          from(l in Learning, where: l.id == ^id and l.project_id == ^project_id and l.status != :retired),
          set: [status: :retired, retired_at: now, updated_at: now]
        )

        Repo.update_all(
          from(p in LearningProposal,
            where: p.learning_id == ^id and p.project_id == ^project_id,
            where: p.status == :pending
          ),
          set: [status: :rejected, decided_by_id: scope.user && scope.user.id, decided_at: now]
        )

        Repo.get!(Learning, id)
      end)

    broadcast_learnings_changed(project_id)
    {:ok, retired}
  end
end
