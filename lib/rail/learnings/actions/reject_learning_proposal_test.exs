defmodule Rail.Learnings.Actions.RejectLearningProposalTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal

  test "a rejected draft stays proposed as the record", %{project: %{id: project_id} = project} do
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, %LearningProposal{status: :rejected, decided_at: %DateTime{}}} =
             Learnings.reject_learning_proposal(system_scope(), proposal)

    assert %Learning{status: :proposed} = Repo.reload!(draft)
    assert_received {:learnings_changed, ^project_id}
  end

  test "Keep rule clears the flag an override put on a rule", %{project: project} do
    rule = learning(project, %{rule: "Don't flag docs", kind: :calibration})
    override = Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: rule.id})

    assert {:ok, _kept} = Learnings.reject_learning_proposal(system_scope(), override)
    assert {:ok, [%Learning{flagged: false, status: :active}]} = Learnings.list_learnings(ids: [rule.id])
  end

  test "a second rejection is told it was already decided", %{project: project} do
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})

    assert {:ok, _rejected} = Learnings.reject_learning_proposal(system_scope(), proposal)
    assert {:error, :already_decided} = Learnings.reject_learning_proposal(system_scope(), proposal)
  end
end
