defmodule Rail.Pipeline.Actions.DecideFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dcf_1", "identifier" => "DCF-1", "title" => "Decide Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Decide Finding"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, finding} =
      Pipeline.save_finding(task, %{
        key: "unhandled-nil",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Nil is not handled",
        problem: "It crashes.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard it.",
        why: "It crashes.",
        rule: "Every caller handles nil.",
        severity: :major,
        recommendation: :fix,
        places: [%{file: "lib/a.ex", line: 3}],
        evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, %{round: 1}} = Pipeline.save_review(task)

    %{task: task, finding: finding}
  end

  test "a ruling is the human's, noted in the round it was made, and said to the page", %{
    task: %{id: task_id},
    finding: finding
  } do
    id = System.unique_integer([:positive])

    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{
        github_id: "dcf-#{id}",
        login: "dana-dcf-#{id}",
        name: "Dana",
        email: "dcf-#{id}@x.test"
      })

    scope = user_scope(user: user)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    assert {:ok,
            %Finding{
              recommendation: :fix,
              decision: :skip,
              decided_by_id: ^user_id,
              notes: [
                %FindingNote{kind: :raised},
                %FindingNote{kind: :ruling, round: 1, decision: :skip, by_id: ^user_id}
              ]
            }} = Pipeline.decide_finding(scope, finding, :skip)

    assert_received {:output_saved, ^task_id}
  end

  test "a ruling changed before the fix round notes each, and the same ruling twice notes it once", %{
    finding: finding
  } do
    {:ok, dismissed} = Pipeline.decide_finding(system_scope(), finding, :skip)
    {:ok, fixed} = Pipeline.decide_finding(system_scope(), dismissed, :fix)

    assert {:ok, %Finding{decision: :fix, notes: notes}} = Pipeline.decide_finding(system_scope(), fixed, :fix)
    assert [:raised, :ruling, :ruling] = Enum.map(notes, & &1.kind)
  end

  test "a task that has left Review has nothing left to rule", %{task: task, finding: finding} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :merged})

    assert {:error, {:invalid_stage, :merged}} = Pipeline.decide_finding(system_scope(), finding, :skip)
  end

  test "a finding is not ruled on while the run works", %{task: task, project: project, finding: finding} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    assert {:error, :stage_running} = Pipeline.decide_finding(system_scope(), finding, :fix)
  end
end
