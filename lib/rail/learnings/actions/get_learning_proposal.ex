defmodule Rail.Learnings.Actions.GetLearningProposal do
  @moduledoc false

  import Ecto.Query

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Repo

  @doc """
  Loads a proposal with its draft or subject rule, the rules it targets with
  their approvers and run counts, and the sightings it rests on.
  """
  def get_learning_proposal(id) when is_binary(id) do
    case Repo.get(LearningProposal, id) do
      %LearningProposal{} = proposal ->
        proposal = Repo.preload(proposal, [:project, :decided_by, :issue, :curator_pass])
        ids = [proposal.learning_id | proposal.target_ids]
        {:ok, rules} = Learnings.list_learnings(ids: ids, project_id: proposal.project_id)
        rules = Map.new(rules, &{&1.id, &1})
        targets = for id <- proposal.target_ids, Map.has_key?(rules, id), do: rules[id]

        evidence =
          Repo.all(
            from o in Observation,
              where: o.id in ^proposal.evidence_ids and o.project_id == ^proposal.project_id,
              order_by: [asc: o.inserted_at, asc: o.id],
              preload: [:actor, task: :issue]
          )

        {:ok, %{proposal | learning: Map.fetch!(rules, proposal.learning_id), targets: targets, evidence: evidence}}

      nil ->
        {:error, :not_found}
    end
  end
end
