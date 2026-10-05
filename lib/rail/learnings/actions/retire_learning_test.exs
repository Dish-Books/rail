defmodule Rail.Learnings.Actions.RetireLearningTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal

  test "retiring sets the status and time, rejects every proposal pending on the rule and broadcasts", %{
    project: %{id: project_id} = project
  } do
    rule = learning(project, %{rule: "Don't flag docs", kind: :calibration}, status: :provisional)
    override = Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: rule.id})
    confirm = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: rule.id})
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, %Learning{status: :retired, retired_at: %DateTime{} = retired_at}} =
             Learnings.retire_learning(system_scope(), rule)

    assert %LearningProposal{status: :rejected, decided_at: %DateTime{}} = Repo.reload!(override)
    assert %LearningProposal{status: :rejected} = Repo.reload!(confirm)
    assert_received {:learnings_changed, ^project_id}

    assert {:ok, %Learning{status: :retired, retired_at: ^retired_at}} = Learnings.retire_learning(system_scope(), rule)
  end

  test "a rule is loaded with its project and approver, or is not found", %{project: %{id: project_id} = project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert {:ok, %Learning{project: %{id: ^project_id}, approved_by: nil}} = Learnings.get_learning(rule.id)
    assert {:error, :not_found} = Learnings.get_learning("lrn_none")
  end
end
