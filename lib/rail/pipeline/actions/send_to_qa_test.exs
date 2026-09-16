defmodule Rail.Pipeline.Actions.SendToQaTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Send To QA Project",
        github_repo: "org/send-to-qa",
        github_installation_id: 47_027,
        linear_workspace: %{
          name: "Send To QA Workspace",
          external_id: "lin_ws_send_to_qa",
          token: "lin_api_token_send_to_qa",
          webhook_secret: "whsec_send_to_qa"
        },
        linear_team_key: "SQA",
        default_branch: "main",
        clone_path: "/tmp/repos/send-to-qa",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :review,
        name: "review role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the review agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sqa_1", "identifier" => "SQA-1", "title" => "Send To QA"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send To QA"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_to_qa",
        started_at: DateTime.utc_now()
      })

    raised = %{
      key: "unhandled-nil",
      title: "Nil is not handled",
      severity: :major,
      recommendation: :fix,
      status: :open
    }

    %{task: task, run: Repo.preload(run, [:task, :role]), raised: raised}
  end

  test "a review that raised nothing goes straight on", %{task: task, run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_qa(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "findings the engineer fixed are not outstanding", %{task: task, run: run, raised: raised} do
    {:ok, _synced} = Pipeline.sync_review_findings(task, [%{raised | status: :fixed}])

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_qa(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "findings the human dismissed are not outstanding either", %{task: task, run: run, raised: raised} do
    {:ok, [finding]} = Pipeline.sync_review_findings(task, [raised])
    {:ok, _dismissed} = Pipeline.decide_review_finding(finding, :skip)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_qa(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a change with something still to fix does not go on", %{task: task, run: run, raised: raised} do
    {:ok, _synced} = Pipeline.sync_review_findings(task, [raised])

    assert {:error, :findings_outstanding} = Pipeline.send_to_qa(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a task that has left review has nothing left to send", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:error, {:invalid_stage, :engineer}} = Pipeline.send_to_qa(run)
  end

  test "nothing is sent while something is still running", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_to_qa(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end
end
