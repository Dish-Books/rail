defmodule Rail.Learnings.Actions.RecordOverrides do
  @moduledoc """
  Records a Fix sent on findings a calibration rule suppressed: a sighting against the rule, once per finding,
  and evidence on the rule's one pending override proposal, which is what flags it.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.InsertObservations

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Records `findings`, each carrying the rule that suppressed it. Returns
  `{:ok, observations}`, the overrides that were new.
  """
  def record_overrides(%Task{id: task_id, project_id: project_id} = task, findings) when is_list(findings) do
    %Task{issue: %Issue{identifier: identifier}} = Repo.preload(task, :issue)

    {:ok, observations} =
      Repo.transaction(fn ->
        observations =
          insert_observations(
            project_id,
            for %ReviewFinding{suppressed_by_id: rule_id} = finding <- findings, is_binary(rule_id) do
              %{
                task_id: task_id,
                source_kind: :override,
                source_id: finding.id,
                actor_id: finding.decided_by_id,
                text: "Fix on: #{finding.title}",
                excerpt: finding.detail,
                learning_id: rule_id
              }
            end
          )

        Enum.each(observations, &flag(project_id, identifier, &1))
        observations
      end)

    if observations != [], do: broadcast_learnings_changed(project_id)
    {:ok, observations}
  end

  # The pending-override index allows one per rule, so a second lands on the first as evidence.
  defp flag(project_id, identifier, %Observation{id: id, learning_id: rule_id}) do
    now = DateTime.utc_now()

    Repo.insert_all(
      LearningProposal,
      [
        %{
          id: UXID.generate!(prefix: "lpr"),
          project_id: project_id,
          action: :override,
          learning_id: rule_id,
          summary: "Fix on #{identifier}",
          evidence_ids: [id],
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict:
        from(p in LearningProposal,
          update: [
            set: [
              evidence_ids: fragment("array_cat(?, EXCLUDED.evidence_ids)", p.evidence_ids),
              summary: fragment("EXCLUDED.summary"),
              updated_at: ^now
            ]
          ]
        ),
      conflict_target: {:unsafe_fragment, "(learning_id) WHERE action = 'override' AND status = 'pending'"}
    )
  end
end
