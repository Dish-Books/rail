defmodule Rail.Learnings.Actions.RejectTaskProposals do
  @moduledoc """
  Rejects the proposals a discarded task left undecided, whatever was chosen for them, since the task they came from
  will never merge. Like the other rejections Rail makes on its own, it carries nobody's name. Run inside the discard's transaction, before the task is deleted, so none is left pending with no
  task. Nothing is broadcast: no page lists them either side of the discard.
  """

  import Ecto.Query

  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Rejects `task`'s pending proposals. Returns `:ok`.
  """
  def reject_task_proposals(%Task{id: task_id}) do
    {_rejected, nil} =
      Repo.update_all(
        from(p in LearningProposal, where: p.task_id == ^task_id and p.status == :pending),
        set: [status: :rejected, decided_by_id: nil, decided_at: DateTime.utc_now()]
      )

    :ok
  end
end
