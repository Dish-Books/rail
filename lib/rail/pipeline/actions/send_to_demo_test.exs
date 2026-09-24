defmodule Rail.Pipeline.Actions.SendToDemoTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :qa,
        name: "qa role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the QA agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_std_1", "identifier" => "STD-1", "title" => "Send To Demo"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send To Demo"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_to_demo",
        started_at: DateTime.utc_now()
      })

    %{task: task, run: Repo.preload(run, [:task, :role])}
  end

  test "a pass that found nothing goes to demo", %{task: task, run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_demo(run)
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  # Whether a change needs a demo at all is the human's call, made on the demo tab.
  test "the demo is left to a person to start", %{task: task, run: run} do
    {:ok, demo} =
      Roles.create_role(system_scope(), Repo.get!(Rail.Projects.Schemas.Project, task.project_id), %{
        backend_id: Repo.one!(Rail.Tools.Schemas.Backend).id,
        stage: :demo,
        name: "demo role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the demo agent."
      })

    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{}} = Pipeline.send_to_demo(run)
    assert %Task{stage: :demo} = Repo.reload!(task)
    assert Repo.get_by(Run, task_id: task.id, role_id: demo.id) == nil
  end

  test "a pass whose findings were all dismissed goes to demo too", %{task: task, run: run} do
    {:ok, raised} =
      Pipeline.sync_qa_findings(task, [
        %{key: "one", title: "One", check: "A check", severity: :blocker, recommendation: :fix, status: :open}
      ])

    for finding <- raised, do: {:ok, _dismissed} = Pipeline.decide_qa_finding(finding, :skip)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_demo(run)
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  test "nothing moves while a finding has no ruling on it", %{task: task, run: run} do
    {:ok, _raised} =
      Pipeline.sync_qa_findings(task, [
        %{key: "one", title: "One", check: "A check", severity: :nit, recommendation: :skip, status: :open}
      ])

    assert {:error, :findings_undecided} = Pipeline.send_to_demo(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "nothing moves while something is still to fix", %{task: task, run: run} do
    {:ok, [finding]} =
      Pipeline.sync_qa_findings(task, [
        %{key: "one", title: "One", check: "A check", severity: :major, recommendation: :fix, status: :open}
      ])

    {:ok, _to_fix} = Pipeline.decide_qa_finding(finding, :fix)

    assert {:error, :findings_outstanding} = Pipeline.send_to_demo(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a task that has not reached QA has nothing to send on", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})

    assert {:error, {:invalid_stage, :review}} = Pipeline.send_to_demo(run)
  end

  test "nothing moves while something is still running", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_to_demo(Repo.reload!(run))
    assert %Task{stage: :qa} = Repo.reload!(task)
  end
end
