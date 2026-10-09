defmodule Rail.Learnings.Actions.GetLearningStats do
  @moduledoc """
  What the rule view shows beyond the rule, every figure counted when asked from the retrieval log, findings and observations.
  """

  import Ecto.Query

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Repo

  @doc """
  Returns `%{runs:, broken:, suppressed:, overrides:, suppressed_findings:, suppressed_tasks:, sources:, activated_by:, pending_override:}`.
  Findings and sources come newest first; a pending override carries the finding its latest sighting was about.
  """
  def get_learning_stats(%Learning{id: id, project_id: project_id}) do
    {:ok, [figures]} = Learnings.list_learnings(ids: [id], project_id: project_id)

    sources =
      Repo.all(
        from o in Observation,
          where: o.learning_id == ^id and o.project_id == ^project_id,
          order_by: [desc: o.inserted_at, desc: o.id],
          preload: [:actor, task: :issue]
      )

    overridden =
      for %Observation{source_kind: :override, source_id: finding_id} <- sources, into: MapSet.new(), do: finding_id

    findings =
      Repo.all(
        from f in Finding,
          where: f.suppressed_by_id == ^id,
          order_by: [desc: f.inserted_at, desc: f.id],
          preload: [task: :issue]
      )

    %{
      runs: figures.run_count,
      broken: figures.broken_count,
      suppressed: figures.suppressed_count,
      overrides: figures.override_count,
      suppressed_findings: Enum.map(findings, &%{finding: &1, overridden?: MapSet.member?(overridden, &1.id)}),
      suppressed_tasks: findings |> Enum.uniq_by(& &1.task_id) |> length(),
      sources: sources,
      activated_by: activated_by(id, project_id),
      pending_override: pending_override(id, project_id, sources, findings)
    }
  end

  defp activated_by(id, project_id) do
    Repo.one(
      from p in LearningProposal,
        where: p.learning_id == ^id and p.project_id == ^project_id,
        where: p.action in [:add, :merge, :rewrite] and p.status == :approved,
        order_by: [desc: p.decided_at],
        limit: 1,
        preload: [:decided_by, :curator_pass]
    )
  end

  defp pending_override(id, project_id, sources, findings) do
    case Repo.one(
           from p in LearningProposal,
             where: p.learning_id == ^id and p.project_id == ^project_id,
             where: p.action == :override and p.status == :pending
         ) do
      %LearningProposal{} = proposal ->
        latest = Enum.find(sources, &(&1.source_kind == :override and &1.id in proposal.evidence_ids))
        finding = latest && Enum.find(findings, &(&1.id == latest.source_id))
        %{proposal: proposal, observation: latest, finding: finding}

      nil ->
        nil
    end
  end
end
