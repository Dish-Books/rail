defmodule Rail.Pipeline.Actions.DismissQuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Dismiss Question Workspace",
        external_id: "lin_ws_dismiss_question",
        token: "lin_api_token_dismiss_question",
        webhook_secret: "whsec_dismiss_question"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Dismiss Question Project 6701",
        github_repo: "org/dismiss-question-6701",
        github_installation_id: 6701,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_dismiss_question_6701",
        linear_team_key: "P6701",
        default_branch: "main",
        clone_path: "/tmp/repos/dismiss-question-6701",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_dismiss_question_1",
      "identifier" => "DSQ-1",
      "title" => "Dismiss Question Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Dismiss Question Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_dismiss_question_1"})

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

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "dismisses a pending question and releases blocked task", %{task: task} do
    {:ok, q} = Pipeline.register_question(task, %{prompt: "Should we proceed?"})

    task = Pipeline.get_task!(system_scope(), task.id)
    assert task.stage_state == :blocked
    assert task.question_id == q.id

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(q.id)

    reloaded_q = Repo.get!(Question, q.id)
    assert reloaded_q.status == :dismissed

    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :awaiting_approval
    assert is_nil(reloaded_task.question_id)
  end

  test "dismissing the front question hands the human the next one instead of releasing", %{task: task} do
    {:ok, first} = Pipeline.register_question(task, %{prompt: "Should we proceed?"})
    {:ok, second} = Pipeline.register_question(task, %{prompt: "Ship behind a flag?"})

    assert Repo.get!(Task, task.id).question_id == first.id

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(first.id)

    # Still blocked, now on the second question; the stage has not resumed.
    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :blocked
    assert reloaded_task.question_id == second.id

    # Dismissing the last one drains the queue and releases the stage.
    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(second.id)

    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :awaiting_approval
    assert is_nil(reloaded_task.question_id)
  end

  test "dismisses question without touching task if task was not parked on it", %{task: task} do
    {:ok, q} = Pipeline.register_question(task, %{prompt: "Should we proceed?"})

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{stage_state: :running, question_id: nil})

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(q)

    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :running
    assert is_nil(reloaded_task.question_id)
  end

  test "returns error when dismissing an answered question", %{task: task, roles: roles} do
    {:ok, _product_run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        conversation_id: "sess_product",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, q_answered} = Pipeline.register_question(task, %{prompt: "Answered question?"})

    {:ok, q_answered} =
      q_answered
      |> Question.changeset(%{answer: "Yes", status: :answered, answered_at: DateTime.utc_now()})
      |> Repo.update()

    assert {:error, :already_resolved} = Pipeline.dismiss_question(q_answered.id)
  end

  test "returns error when dismissing an already dismissed question", %{task: task} do
    {:ok, q_dismissed} = Pipeline.register_question(task, %{prompt: "Dismissed question?"})
    {:ok, q_dismissed} = Pipeline.dismiss_question(q_dismissed)

    assert {:error, :already_resolved} = Pipeline.dismiss_question(q_dismissed.id)
  end

  test "validates scope authorization and existence", %{task: task} do
    assert {:error, :not_authorized} = Pipeline.dismiss_question(%Rail.Scope{}, "qst_any")
    assert {:error, :not_found} = Pipeline.dismiss_question("qst_nonexistent")
    assert {:error, :not_found} = Pipeline.dismiss_question(123)

    {:ok, q} = Pipeline.register_question(task, %{prompt: "Scoped question?"})

    user_scope = %Rail.Scope{user: %{id: "usr_test"}}
    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(user_scope, q.id)
  end
end
