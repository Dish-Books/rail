defmodule Rail.Learnings.Actions.CreateLearning do
  @moduledoc """
  A rule a person writes themselves: active at once, with them as its approver.
  """

  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueueEmbedding

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Adds the rule `attrs` describe to `project`, queued for embedding. Returns `{:ok, learning}`.
  """
  def create_learning(%Scope{} = scope, %Project{id: project_id}, attrs) do
    changeset =
      Learning.changeset(
        %Learning{
          project_id: project_id,
          status: :active,
          activated_at: DateTime.utc_now(),
          approved_by_id: scope.user && scope.user.id
        },
        attrs
      )

    result =
      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, learning} ->
            enqueue_embedding([learning])
            learning

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, learning} <- result do
      broadcast_learnings_changed(project_id)
      {:ok, learning}
    end
  end
end
