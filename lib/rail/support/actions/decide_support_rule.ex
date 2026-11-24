defmodule Rail.Support.Actions.DecideSupportRule do
  @moduledoc false

  import Ecto.Query

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.Conversation

  @doc """
  Approves or rejects the rule `proposal_id` the agent proposed in `conversation`. Returns `{:ok, proposal}`, or
  `{:error, reason}`: `:not_found` for a rule not this conversation's, `:drafting` while a pass runs, `:already_decided`,
  or `:retired` for a draft no longer proposed.
  """
  def decide_support_rule(%Scope{} = scope, %Conversation{id: id} = conversation, proposal_id, choice)
      when choice in [:approved, :rejected] do
    current = Repo.one!(from c in Conversation, where: c.id == ^id and c.project_id == ^conversation.project_id)

    result =
      with true <- Scope.can_access_project?(scope, current.project_id) || {:error, :not_found},
           true <- not Conversation.drafting?(current) || {:error, :drafting},
           {:ok, %LearningProposal{support_conversation_id: ^id} = proposal} <-
             Learnings.get_learning_proposal(proposal_id) do
        decide(scope, proposal, choice)
      else
        {:ok, %LearningProposal{}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end

    # Every open tab reloads, so one that lost the race shows the decision that won it.
    Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
    result
  end

  defp decide(scope, proposal, :approved), do: Learnings.approve_learning_proposal(scope, proposal)
  defp decide(scope, proposal, :rejected), do: Learnings.reject_learning_proposal(scope, proposal)
end
