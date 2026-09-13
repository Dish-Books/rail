defmodule Rail.Pipeline.Utils.RegisterAskedQuestionsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.RegisterAskedQuestions

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} =
      Rail.Backends.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Run Finished Workspace",
        external_id: "lin_ws_run_finished",
        token: "lin_api_token_run_finished",
        webhook_secret: "whsec_run_finished"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Run Finished Project 3301",
        github_repo: "org/run-finished-3301",
        github_installation_id: 3301,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_run_finished_3301",
        linear_team_key: "P3301",
        default_branch: "main",
        clone_path: "/tmp/repos/run-finished-3301",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_run_finished_1",
      "identifier" => "RFN-1",
      "title" => "Run Finished Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Run Finished Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise the question read-back, not Linear publishing.
    {:ok, task} =
      Pipeline.update_task(task, %{issue_id: nil, stage: :product})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        conversation_id: "sess_run_finished",
        status: :running,
        started_at: DateTime.utc_now()
      })

    spawn_os_process = fn ->
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/run_finished/#{UXID.generate!()}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    say = fn os_process, text ->
      Repo.insert!(%RunEvent{
        run_id: run.id,
        os_process_id: os_process.id,
        line: ~s({"type":"assistant","message":{"content":[{"type":"text","text":"#{text}"}]}})
      })
    end

    %{task: task, run: run, spawn_os_process: spawn_os_process, say: say}
  end

  test "files only the questions the exiting process itself asked", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    first = spawn_os_process.()
    say.(first, "[QUESTION: Which database?] [OPTIONS: Postgres, SQLite]")

    second = spawn_os_process.()
    say.(second, "[QUESTION: Which region?]")

    assert [%DetectedQuestion{prompt: "Which database?"}] = register_asked_questions(first, run)

    assert [%Question{prompt: "Which database?", options: ["Postgres", "SQLite"]}] =
             pending_questions(task_id)
  end

  test "registers a batch in the order it was asked, parks the task, and blocks the run", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "[QUESTION: Which database?] [OPTIONS: PG, MySQL]")
    say.(os_process, "[QUESTION: Ship behind a flag?]")
    say.(os_process, "[QUESTION: Which database?]")

    assert [%DetectedQuestion{}, %DetectedQuestion{}] = register_asked_questions(os_process, run)

    pending = pending_questions(task_id)
    assert Enum.map(pending, & &1.prompt) == ["Which database?", "Ship behind a flag?"]

    assert %Task{} = Repo.get!(Task, task_id)
    assert %Run{status: :blocked_on_input} = Repo.get!(Run, run.id)
  end

  test "settles a process that asked nothing without parking the task", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "Postgres it is.")

    assert register_asked_questions(os_process, run) == []
    assert pending_questions(task_id) == []
  end

  test "leaves out what Rail and the human contributed between turns", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "[QUESTION: Which database?]")

    Repo.insert!(%RunEvent{
      run_id: run.id,
      os_process_id: os_process.id,
      line: "[human] [QUESTION: Have you taken another look?]"
    })

    assert [%DetectedQuestion{prompt: "Which database?"}] =
             register_asked_questions(os_process, run)

    assert [%Question{prompt: "Which database?"}] = pending_questions(task_id)
  end
end
