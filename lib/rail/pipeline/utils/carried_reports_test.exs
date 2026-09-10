defmodule Rail.Pipeline.Utils.CarriedReportsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CarriedReports

  alias Rail.Pipeline.Schemas.Task

  test "returns empty string and empty entries when task has no outstanding reports" do
    task = create_test_task(%{outstanding_reports: []})

    assert build_carried_gate_reports(task) == ""
    assert collect_report_entries(task) == []
  end

  test "formats carried gate reports and supports excluding a specific gate" do
    project = create_test_project()
    role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        outstanding_reports: [role_rev.id, role_qa.id]
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_rev.id,
      status: :finished,
      output: "Reviewer finding: unused variable."
    })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_qa.id,
      status: :finished,
      output: "QA finding: button alignment broken."
    })

    text_all = build_carried_gate_reports(task)
    assert text_all =~ "Also outstanding: what the other gates last reported"
    assert text_all =~ "### Reviewer\n\nReviewer finding: unused variable."
    assert text_all =~ "### QA Tester\n\nQA finding: button alignment broken."

    text_except = build_carried_gate_reports(task, except: role_rev.id)
    assert text_except =~ "### QA Tester\n\nQA finding: button alignment broken."
    refute text_except =~ "### Reviewer"
  end

  test "ignores role_runs with empty or missing output" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :review, name: "Empty Reviewer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        outstanding_reports: [role.id]
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role.id,
      status: :finished,
      output: "   "
    })

    assert build_carried_gate_reports(task) == ""
    assert collect_report_entries(task) == []
  end

  test "falls back to role_id when role schema is not found in database" do
    project = create_test_project()
    non_existent_role_id = "rol_000000000000000000000001"

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        outstanding_reports: [non_existent_role_id]
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: non_existent_role_id,
      status: :finished,
      output: "Finding from unknown role"
    })

    assert [{^non_existent_role_id, ^non_existent_role_id, "Finding from unknown role"}] =
             collect_report_entries(task)

    assert build_carried_gate_reports(task) =~ "### #{non_existent_role_id}\n\nFinding from unknown role"
  end
end
