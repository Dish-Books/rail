defmodule Rail.Pipeline.Actions.DismissQuestionTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
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

  test "dismissing the only question resumes the run and says it was waved off", %{
    task: task,
    run: %Run{id: run_id} = run
  } do
    {:ok, q} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Should we proceed?"})

    assert Repo.reload!(run).status == :blocked_on_input

    test_pid = self()

    expect(Runs, :start_os_process, fn %Run{id: ^run_id} = spawned, argv ->
      send(test_pid, {:spawned, argv})
      {:ok, %OsProcess{run: spawned, task: task}}
    end)

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(q)

    assert pending_questions(task.id) == []
    assert Repo.get!(Question, q.id).delivered_at

    assert_receive {:spawned, argv}
    assert Enum.any?(argv, &(&1 =~ "Should we proceed?" and &1 =~ "Dismissed without an answer"))
  end

  test "dismissing one of a batch leaves the rest and does not resume the run", %{task: task, run: run} do
    {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Should we proceed?"})
    {:ok, second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Ship behind a flag?"})

    assert Enum.map(pending_questions(task.id), & &1.id) == [first.id, second.id]

    # No spawn is stubbed: resuming the run here would raise on the unexpected call.
    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(first)

    assert Repo.reload!(run).status == :blocked_on_input
    assert Enum.map(pending_questions(task.id), & &1.id) == [second.id]
    refute Repo.get!(Question, first.id).delivered_at
  end

  test "leaves a task that is no longer parked alone", %{task: task, run: run} do
    {:ok, q} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Should we proceed?"})

    # Another question is still pending, so waving this one off resumes nothing.
    {:ok, _second} =
      Pipeline.register_question(run, %DetectedQuestion{prompt: "And the migration?"})

    stub(Runs, :start_os_process, fn _run, _argv -> {:error, :not_expected} end)

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(q)

    assert Repo.reload!(run).status == :blocked_on_input
    assert [%Question{prompt: "And the migration?"}] = pending_questions(task.id)
  end

  test "returns error when dismissing an answered question", %{task: task, run: run, roles: roles} do
    {:ok, _product_run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        conversation_id: "sess_product",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, q_answered} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Answered question?"})

    {:ok, q_answered} =
      q_answered
      |> Question.changeset(%{answer: "Yes", status: :answered, answered_at: DateTime.utc_now()})
      |> Repo.update()

    assert {:error, :already_resolved} = Pipeline.dismiss_question(q_answered)
  end

  test "returns error when dismissing an already dismissed question", %{run: run} do
    {:ok, q_dismissed} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Dismissed question?"})
    {:ok, q_dismissed} = Pipeline.dismiss_question(q_dismissed)

    assert {:error, :already_resolved} = Pipeline.dismiss_question(q_dismissed)
  end
end
