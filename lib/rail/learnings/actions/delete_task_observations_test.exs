defmodule Rail.Learnings.Actions.DeleteTaskObservationsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.Finding

  test "deletes the task's observations, keeps another task's and the rule one of them backed", %{project: project} do
    %Learning{id: rule_id} = rule = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration})
    task = learnings_task(project, "DTO-1")
    other = learnings_task(project, "DTO-2")

    {:ok, [%Observation{learning_id: ^rule_id}]} =
      Learnings.record_overrides(task, [%Finding{id: "fnd_dto_1", title: "Missing @doc", suppressed_by_id: rule.id}])

    {:ok, [%Observation{id: kept_id}]} =
      Learnings.record_overrides(other, [%Finding{id: "fnd_dto_2", title: "Missing @doc", suppressed_by_id: rule.id}])

    assert :ok = Learnings.delete_task_observations(task)

    assert [%Observation{id: ^kept_id}] =
             Repo.all(from o in Observation, where: o.task_id in ^[task.id, other.id])

    assert %Learning{id: ^rule_id} = Repo.get(Learning, rule_id)
  end
end
