defmodule Rail.Pipeline.Utils.ReviewRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Review Workspace",
        external_id: "lin_ws_settle_review",
        token: "lin_api_token_settle_review",
        webhook_secret: "whsec_settle_review"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Review Project 14605",
        github_repo: "org/settle-review-14605",
        github_installation_id: 14_605,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_review_14605",
        linear_team_key: "P14605",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-review-14605",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_settle_review_1",
      "identifier" => "S14605-1",
      "title" => "Settle Review Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Settle Review Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    {:ok, task} = Pipeline.update_task(task, %{stage: :review})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:review].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, [:task, :role])

    %{backend: backend, project: project, issue: issue, task: task, roles: roles, run: run}
  end

  test "a pass hands the change to QA", %{task: task, run: run} do
    Runs.append_run_event(run, "Looks right.\n\nVERDICT: APPROVED")

    assert %Run{} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.get!(Task, task.id)
  end

  test "changes requested sends it back with the findings as the engineer's next turn", %{
    task: task,
    run: run,
    roles: roles
  } do
    Runs.append_run_event(run, "The guard is inverted.\n\nVERDICT: CHANGES REQUESTED")

    {:ok, engineer_run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_engineer",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert %Run{} = review_run_finished(run, [])
    assert %Task{stage: :engineer, rework_cycles: 1, outstanding_reports: []} = Repo.get!(Task, task.id)
    assert %Run{pending_answer: note} = Repo.reload!(engineer_run)
    assert note =~ "The guard is inverted."
  end

  test "the gate is listed as having reported on the change", %{task: task, run: run, roles: roles} do
    Runs.append_run_event(run, "VERDICT: APPROVED")
    review_role_id = roles[:review].id

    assert %Run{} = review_run_finished(run, [])
    assert %Task{outstanding_reports: [^review_role_id]} = Repo.get!(Task, task.id)
  end

  test "a gate out of rework budget records the reason on its run instead of moving", %{task: task, run: run} do
    {:ok, _task} = Pipeline.update_task(task, %{rework_cycles: 9})
    Runs.append_run_event(run, "Still wrong.\n\nVERDICT: CHANGES REQUESTED")
    run = Repo.preload(run, [:task, :role], force: true)

    assert %Run{error: error} = review_run_finished(run, [])
    assert error =~ "still requesting changes"
    assert %Task{stage: :review} = Repo.get!(Task, task.id)
  end
end
