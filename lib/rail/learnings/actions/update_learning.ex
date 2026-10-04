defmodule Rail.Learnings.Actions.UpdateLearning do
  @moduledoc """
  A person's edit to a rule, or to a proposal's draft. New text is embedded
  again, and an edit is the ruling on any override flagging the rule.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueueEmbedding

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Writes `attrs` to `learning`. Returns `{:ok, learning}` as it now stands.
  """
  def update_learning(%Scope{} = scope, %Learning{id: id, project_id: project_id} = learning, attrs) do
    changeset = Learning.changeset(learning, attrs)
    reworded? = Ecto.Changeset.changed?(changeset, :rule) or Ecto.Changeset.changed?(changeset, :why)

    result =
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, updated} ->
            if reworded?, do: enqueue_embedding([updated])

            Repo.update_all(
              from(p in LearningProposal,
                where: p.learning_id == ^id and p.project_id == ^project_id,
                where: p.action == :override and p.status == :pending
              ),
              set: [status: :approved, decided_by_id: scope.user && scope.user.id, decided_at: DateTime.utc_now()]
            )

            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, updated} <- result do
      broadcast_learnings_changed(project_id)
      {:ok, updated}
    end
  end
end
