defmodule Rail.Learnings.Actions.RecordOverridesTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.Finding

  setup %{project: project} do
    rule = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration})
    %{rule: rule, task: learnings_task(project, "OVR-1")}
  end

  test "the first override opens a pending override proposal that flags the rule", %{
    rule: %{id: rule_id} = rule,
    task: %{project_id: project_id} = task
  } do
    finding = %Finding{id: "fnd_ovr_1", title: "Missing @doc", suppressed_by_id: rule.id, decision: :fix}
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, [%Observation{id: observation_id, source_kind: :override, learning_id: ^rule_id}]} =
             Learnings.record_overrides(task, [finding])

    assert [
             %LearningProposal{
               action: :override,
               status: :pending,
               summary: "Fix on OVR-1",
               evidence_ids: [^observation_id]
             }
           ] =
             Repo.all(from p in LearningProposal, where: p.learning_id == ^rule_id)

    assert {:ok, [%Learning{flagged: true}]} = Learnings.list_learnings(ids: [rule_id])
    assert_received {:learnings_changed, ^project_id}
  end

  test "a later override joins the same proposal, and the same finding again adds nothing", %{rule: rule, task: task} do
    first = %Finding{id: "fnd_ovr_1", title: "Missing @doc", suppressed_by_id: rule.id}
    second = %Finding{id: "fnd_ovr_2", title: "Missing @doc again", suppressed_by_id: rule.id}
    unsuppressed = %Finding{id: "fnd_ovr_3", title: "Not suppressed"}

    {:ok, [%{id: first_id}]} = Learnings.record_overrides(task, [first])
    {:ok, [%{id: second_id}]} = Learnings.record_overrides(task, [second, unsuppressed])
    assert {:ok, []} = Learnings.record_overrides(task, [first])

    assert [%LearningProposal{evidence_ids: [^first_id, ^second_id]}] =
             Repo.all(from p in LearningProposal, where: p.learning_id == ^rule.id)
  end
end
