defmodule Rail.Pipeline.Actions.ListQuestionsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "List Questions Workspace",
        external_id: "lin_ws_list_questions",
        token: "lin_api_token_list_questions",
        webhook_secret: "whsec_list_questions"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "List Questions Project 7201",
        github_repo: "org/list-questions-7201",
        github_installation_id: 7201,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_list_questions_7201",
        linear_team_key: "P7201",
        default_branch: "main",
        clone_path: "/tmp/repos/list-questions-7201",
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
      "id" => "lin_list_questions_1",
      "identifier" => "LQS-1",
      "title" => "List Questions Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "List Questions Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    %{project: project, issue: issue, task: task, run: run, roles: roles}
  end

  test "lists questions by project and filters by status", %{project: project, task: task, roles: roles} do
    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        conversation_id: "sess_product",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    {:ok, q_answered} = Pipeline.register_question(run, %DetectedQuestion{prompt: "P1 Answered"})

    {:ok, _q_answered} =
      q_answered
      |> Question.changeset(%{answer: "Because", status: :answered, answered_at: DateTime.utc_now()})
      |> Repo.update()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_list_questions_2",
      "identifier" => "LQS-2",
      "title" => "Second Task"
    })

    {:ok, issue2} = Issues.create_issue(project, %{description: "Second Task"})
    {:ok, task1b} = Pipeline.create_task(issue2, :product)

    {:ok, run1b} =
      Runs.create_run(%{
        task_id: task1b.id,
        role_id: roles[:product].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run1b = Repo.preload(run1b, task: :issue)

    {:ok, q1} = Pipeline.register_question(run1b, %DetectedQuestion{prompt: "P1 Pending"})

    {:ok, project2} =
      Projects.create_project(system_scope(), %{
        name: "List Questions Project Two",
        github_repo: "org/list-questions-two",
        github_installation_id: 7204,
        linear_team_id: "team_list_questions_two",
        linear_team_key: "LQ2",
        default_branch: "main",
        clone_path: "/tmp/repos/list-questions-two",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_list_questions_3",
      "identifier" => "LQ2-1",
      "title" => "Other Project Task"
    })

    {:ok, issue3} = Issues.create_issue(project2, %{description: "Other Project Task"})
    {:ok, task2} = Pipeline.create_task(issue3, :product)

    {:ok, role2} =
      Roles.create_role(system_scope(), project2, %{
        backend_id: roles[:product].backend_id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    {:ok, run2} =
      Runs.create_run(%{
        task_id: task2.id,
        role_id: role2.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run2 = Repo.preload(run2, task: :issue)

    {:ok, _q3} = Pipeline.register_question(run2, %DetectedQuestion{prompt: "P2 Pending"})

    results_all = Pipeline.list_questions(project.id)
    assert length(results_all) == 2

    results_pending = Pipeline.list_questions(project, status: :pending)
    assert length(results_pending) == 1
    assert hd(results_pending).id == q1.id

    results_multi_status = Pipeline.list_questions(project.id, status: [:pending, :answered])
    assert length(results_multi_status) == 2
  end

  test "lists questions by task and supports order_by", %{task: task, run: run} do
    {:ok, q1} = Pipeline.register_question(run, %DetectedQuestion{prompt: "First"})
    {:ok, _dismissed} = Pipeline.dismiss_question(q1)
    {:ok, q2} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Second"})

    desc_order = Pipeline.list_questions(task.id, order_by: [desc: :inserted_at])
    assert Enum.map(desc_order, & &1.id) == [q2.id, q1.id]

    asc_order = Pipeline.list_questions(task, order_by: [asc: :inserted_at])
    assert Enum.map(asc_order, & &1.id) == [q1.id, q2.id]
  end

  test "filters a project's questions down to the pending ones", %{project: project, task: task, roles: roles} do
    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        conversation_id: "sess_product",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    {:ok, q_answered} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Answered question?"})

    {:ok, _q_answered} =
      q_answered
      |> Question.changeset(%{answer: "Because", status: :answered, answered_at: DateTime.utc_now()})
      |> Repo.update()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_list_questions_pending",
      "identifier" => "LQS-9",
      "title" => "Pending Question Task"
    })

    {:ok, issue_pending} = Issues.create_issue(project, %{description: "Pending Question Task"})
    {:ok, pending_task} = Pipeline.create_task(issue_pending, :product)

    {:ok, pending_run} =
      Runs.create_run(%{
        task_id: pending_task.id,
        role_id: roles[:product].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    pending_run = Repo.preload(pending_run, task: :issue)

    {:ok, q_pending} = Pipeline.register_question(pending_run, %DetectedQuestion{prompt: "Still open?"})

    pending_list = Pipeline.list_questions(project.id, status: :pending)
    assert length(pending_list) == 1
    assert hd(pending_list).id == q_pending.id

    global_pending = Pipeline.list_questions(nil, status: :pending)
    assert Enum.any?(global_pending, &(&1.id == q_pending.id))
  end

  test "returns nothing for targets that hold no questions" do
    assert [] = Pipeline.list_questions("prj_test")
    assert [] = Pipeline.list_questions("tsk_test")
    assert [] = Pipeline.list_questions()
    assert [] = Pipeline.list_questions("prj_test", status: :pending)
    assert [] = Pipeline.list_questions("prj_test", status: :pending, order_by: [asc: :inserted_at])
    assert [] = Pipeline.list_questions(nil, status: :pending)
  end

  test "get_question", %{run: run} do
    {:ok, %Question{id: expected_id}} =
      Pipeline.register_question(run, %DetectedQuestion{prompt: "Which option?"})

    assert {:ok, %Question{id: ^expected_id}} = Pipeline.get_question(expected_id)
    assert {:error, :not_found} = Pipeline.get_question("qst_nonexistent")
  end

  test "supports preload option", %{task: %Rail.Pipeline.Schemas.Task{id: expected_task_id}, run: run} do
    {:ok, %Question{id: q_id}} =
      Pipeline.register_question(run, %DetectedQuestion{
        prompt: "Question prompt 7213?"
      })

    assert [%Question{id: ^q_id, task: %Rail.Pipeline.Schemas.Task{id: ^expected_task_id}}] =
             Pipeline.list_questions(expected_task_id, preload: [:task])
  end
end
