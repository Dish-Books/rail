defmodule Rail.Learnings.Actions.CountLearningsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal

  test "counts pending proposals and each rule status, for one project or all", %{project: project} do
    learning(project, %{rule: "Active", kind: :convention})
    learning(project, %{rule: "Provisional", kind: :convention}, status: :provisional)
    learning(project, %{rule: "Retired", kind: :convention}, status: :retired)
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})

    assert %{review: 1, active: 1, provisional: 1, retired: 1} = Learnings.count_learnings(project_id: project.id)
    assert %{review: review, active: active} = Learnings.count_learnings()
    assert review >= 1 and active >= 1
    assert %{review: 0, active: 0} = Learnings.count_learnings(project_id: "prj_none")
  end
end
