defmodule Rail.Learnings.Actions.GetLearningStatsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline
  alias Rail.Roles

  setup %{project: project} do
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    calibration = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration, pinned: true})
    convention = learning(project, %{rule: "Take the scope first", kind: :convention, pinned: true})
    task = learnings_task(project, "STA-1", :review)
    other_task = learnings_task(project, "STA-2", :review)

    runs =
      for task <- [task, other_task], n <- 1..2 do
        {:ok, run} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: lead.id,
            status: :finished,
            started_at: DateTime.utc_now(),
            conversation_id: "sess_sta_#{task.id}_#{n}"
          })

        run
      end

    Enum.each(runs, &Learnings.retrieve_learnings(&1, []))

    finding = fn key, rule ->
      %{
        key: key,
        kind: :code,
        raised_by: :code_reviewer,
        title: "Finding #{key}",
        problem: "A task with no worktree crashes the page.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard the nil in the action.",
        why: "It crashes.",
        rule: "Every caller handles a missing worktree.",
        severity: :nit,
        recommendation: :fix,
        checklist_rule: rule,
        places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}],
        evidence: [%{name: "The clause", kind: :code, file: "lib/a.ex", line: 3}]
      }
    end

    for finding <- [finding.("doc-a", calibration.id), finding.("broke", convention.id)],
        do: {:ok, _saved} = Pipeline.save_finding(task, finding)

    for finding <- [finding.("doc-b", calibration.id)],
        do: {:ok, _saved} = Pipeline.save_finding(other_task, finding)

    %{calibration: calibration, convention: convention, task: task, other_task: other_task}
  end

  test "counts runs given it, findings suppressed and overrides, with findings newest first and overrides marked", %{
    calibration: calibration,
    task: task
  } do
    [doc_a] = for f <- Pipeline.list_findings(task), f.key == "doc-a", do: f
    {:ok, %{id: fixed_id} = fixed} = Pipeline.decide_finding(system_scope(), doc_a, :fix)
    {:ok, _flagged} = Learnings.record_overrides(task, [fixed])

    assert %{
             runs: 4,
             broken: 0,
             suppressed: 2,
             overrides: 1,
             suppressed_tasks: 2,
             suppressed_findings: [
               %{finding: %{key: "doc-b"}, overridden?: false},
               %{finding: %{id: ^fixed_id}, overridden?: true}
             ],
             sources: [%{source_kind: :override}],
             activated_by: nil,
             pending_override: %{
               proposal: %LearningProposal{action: :override},
               finding: %{id: ^fixed_id},
               observation: %{source_kind: :override}
             }
           } = Learnings.get_learning_stats(calibration)
  end

  test "broken anyway counts findings citing a rule on tasks whose runs were given it", %{convention: convention} do
    assert %{runs: 4, broken: 1, suppressed: 0, overrides: 0, pending_override: nil} =
             Learnings.get_learning_stats(convention)
  end

  test "sources end with the proposal that activated the rule", %{project: project} do
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)

    proposal =
      Repo.insert!(%LearningProposal{
        project_id: project.id,
        action: :add,
        learning_id: draft.id,
        summary: "same correction 3 times"
      })

    {:ok, _approved} = Learnings.approve_learning_proposal(system_scope(), proposal)

    assert %{activated_by: %LearningProposal{summary: "same correction 3 times"}, sources: []} =
             Learnings.get_learning_stats(Repo.reload!(draft))
  end
end
