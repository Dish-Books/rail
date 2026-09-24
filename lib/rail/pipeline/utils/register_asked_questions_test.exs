defmodule Rail.Pipeline.Utils.RegisterAskedQuestionsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.RegisterAskedQuestions

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} =
      Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_run_finished_1",
              "identifier" => "RFN-1",
              "title" => "Run Finished Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Run Finished Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    {:ok, run} =
      Pipeline.create_run(%{
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

  test "a run whose role is gone has no agent to have asked anything", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "[QUESTION: Which database?]")

    {:ok, _deleted} = Roles.delete_role(system_scope(), Repo.preload(run, :role).role)

    assert register_asked_questions(os_process, run) == []
    assert pending_questions(task_id) == []
  end
end
