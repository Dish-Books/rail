defmodule Rail.Learnings.Actions.FinalizeTaskProposals do
  @moduledoc """
  A merged task's proposals decided as their people chose, each approved or rejected as the one who chose it. A draft
  retired since it was chosen is rejected instead, and a proposal nobody chose stays pending, to be decided on the task.
  """

  import Ecto.Query

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Decides `task`'s chosen proposals, oldest first. Returns `:ok`, or the first `{:error, reason}` an approval gave, the
  proposals before it decided.
  """
  def finalize_task_proposals(%Task{id: task_id}) do
    from(p in LearningProposal,
      where: p.task_id == ^task_id and p.status == :pending and not is_nil(p.choice),
      order_by: [asc: p.inserted_at, asc: p.id],
      preload: :decided_by
    )
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn proposal, :ok ->
      case finalize(proposal, proposal.choice) do
        {:error, reason} -> {:halt, {:error, reason}}
        _decided -> {:cont, :ok}
      end
    end)
  end

  # Approving one can reject another of the task's on the rule it retires, which is then already decided.
  defp finalize(%LearningProposal{} = proposal, :approved) do
    case Learnings.approve_learning_proposal(chooser(proposal), proposal) do
      {:error, :retired} -> finalize(proposal, :rejected)
      {:error, :already_decided} -> :ok
      result -> result
    end
  end

  defp finalize(%LearningProposal{} = proposal, :rejected) do
    case Learnings.reject_learning_proposal(chooser(proposal), proposal) do
      {:error, :already_decided} -> :ok
      result -> result
    end
  end

  defp chooser(%LearningProposal{decided_by: nil}), do: Scope.for_system()
  defp chooser(%LearningProposal{decided_by: user}), do: Scope.for_user(user)
end
