defmodule Rail.Pipeline.Utils.ProductRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ProductRunFinished

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
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Product Workspace",
        external_id: "lin_ws_settle_product",
        token: "lin_api_token_settle_product",
        webhook_secret: "whsec_settle_product"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Product Project 14601",
        github_repo: "org/settle-product-14601",
        github_installation_id: 14_601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_product_14601",
        linear_team_key: "P14601",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-product-14601",
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
      "id" => "lin_settle_product_1",
      "identifier" => "S14601-1",
      "title" => "Settle Product Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Settle Product Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, [:task, :role])

    %{backend: backend, project: project, issue: issue, task: task, roles: roles, run: run}
  end

  test "leaves the task where it is: a human approves the ticket", %{task: task, run: run} do
    assert %Run{} = product_run_finished(run, [])
    assert %Task{stage: :product} = Repo.get!(Task, task.id)
  end
end
