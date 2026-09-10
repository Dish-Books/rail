defmodule Rail.Pipeline.Actions.DismissQuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
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
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    {:ok, task} = Pipeline.create_task(issue)

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

  test "dismisses question without touching task if task was not parked on it", %{task: task} do
    {:ok, q} = Pipeline.register_question(task, %{prompt: "Should we proceed?"})

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{stage_state: :running, question_id: nil})

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(q)

    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :running
    assert is_nil(reloaded_task.question_id)
  end

  test "returns error when dismissing an answered question", %{task: task} do
    {:ok, q_answered} = Pipeline.register_question(task, %{prompt: "Answered question?"})
    {:ok, q_answered} = Pipeline.answer_question(q_answered, "Yes")

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
