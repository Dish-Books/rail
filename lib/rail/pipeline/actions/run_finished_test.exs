defmodule Rail.Pipeline.Actions.RunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Run Finished Project",
        github_repo: "org/run-finished",
        github_installation_id: 43_001,
        linear_workspace: %{
          name: "Run Finished Workspace",
          external_id: "lin_ws_run_finished",
          token: "lin_api_token_run_finished",
          webhook_secret: "whsec_run_finished"
        },
        linear_team_key: "RUN",
        default_branch: "main",
        clone_path: "/tmp/repos/run-finished",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :demo, :debugger], fn stage ->
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

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_run_finished_1",
              "identifier" => "RUN-1",
              "title" => "Run Finished Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Run Finished Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # Product and architect both check that their agent left its file behind, so a
    # run meant to read as clean needs one there.
    File.mkdir_p!(Path.join(task.scratch_path, "tickets"))
    File.write!(Path.join([task.scratch_path, "tickets", "RUN-1.md"]), "---\ntitle: Run Finished Issue\n---\n\nBody.\n")

    exited = fn stage, run_attrs ->
      {:ok, run} =
        Pipeline.create_run(
          Map.merge(
            %{
              task_id: task.id,
              role_id: roles[stage].id,
              status: :running,
              conversation_id: "sess_run_finished",
              started_at: DateTime.utc_now()
            },
            run_attrs
          )
        )

      {:ok, os_process} =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: "/tmp/run_finished/#{run.id}.ndjson",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {run, os_process}
    end

    # Every push opens the task's pull request if it has none.
    Req.Test.stub(Rail.GitHub.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", _pulls} ->
          Req.Test.json(conn, [])

        {"POST", _pulls} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 7, "html_url" => "https://github.com/org/repo/pull/7", "draft" => true})
      end
    end)

    %{project: project, task: task, roles: roles, exited: exited}
  end

  test "records the exit against the run and marks the process finished", %{exited: exited} do
    {run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{status: :finished, exit_code: 0, completed_at: %DateTime{}}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %OsProcess{status: :finished} = Repo.reload!(os_process)
    assert %Run{status: :finished} = Repo.reload!(run)
  end

  test "usage accumulates across the processes a run is carried by", %{exited: exited} do
    {run, os_process} = exited.(:product, %{usage: %Run.Usage{input_tokens: 10, output_tokens: 5}})

    {:ok, _run} =
      Pipeline.run_finished(os_process, %{
        exit_code: 0,
        usage: %Run.Usage{input_tokens: 1, output_tokens: 2}
      })

    assert %Run{usage: %Run.Usage{input_tokens: 11, output_tokens: 7}} = Repo.reload!(run)
  end

  test "a non-zero exit records the error and concludes nothing", %{task: task, exited: exited} do
    {_run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{exit_code: 2, error: "Exited with code 2", stage_outcome: :in_progress}} =
             Pipeline.run_finished(os_process, %{exit_code: 2, error: "Exited with code 2"})

    assert %Task{stage: :product} = Repo.reload!(task)
  end

  test "a process whose run is gone has nothing to settle", %{exited: exited} do
    {run, os_process} = exited.(:product, %{})
    Repo.delete!(run)

    assert {:error, :invalid_state} = Pipeline.run_finished(os_process)
  end

  test "a message queued while the run worked goes out once it is idle", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:product, %{pending_chat: "Please also add a test"})

    test_pid = self()

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:dispatched, argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0}, async: false)

    # The queued text is taken off the row as it goes out, and carried in the prompt.
    assert %Run{pending_chat: nil} = Repo.reload!(run)
    assert_received {:dispatched, argv}
    assert Enum.any?(argv, &(&1 =~ "Please also add a test"))
  end

  test "a run that came back clean latches done and moves nothing", %{task: task, exited: exited} do
    {run, os_process} = exited.(:product, %{})

    Pipeline.append_run_events(run.id, nil, ["The ticket is written."])

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})

    # Product hands on only when a human approves; the exit itself moves nothing.
    assert %Task{stage: :product} = Repo.reload!(task)
  end

  test "a run that already had its say is left alone however often it exits", %{task: task, exited: exited} do
    {run, os_process} = exited.(:product, %{stage_outcome: :done})

    Pipeline.append_run_events(run.id, nil, ["Still done."])

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :product} = Repo.reload!(task)
  end

  test "a run that asked something parks on it rather than concluding", %{task: task, exited: exited} do
    {run, os_process} = exited.(:product, %{})

    # Questions are read back from what this process wrote, so the lines carry it.
    now = DateTime.utc_now()

    Repo.insert_all(RunEvent, [
      %{
        id: UXID.generate!(),
        run_id: run.id,
        os_process_id: os_process.id,
        line: "[QUESTION: Which database?]",
        inserted_at: now,
        updated_at: now
      }
    ])

    assert {:ok, %Run{stage_outcome: :in_progress}} = Pipeline.run_finished(os_process, %{exit_code: 0})

    assert [%{prompt: "Which database?"}] = pending_questions(task.id)
  end

  test "a review run records what it found and leaves the task at review", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    File.mkdir_p!(Path.join(task.scratch_path, "reviews"))

    File.write!(Path.join([task.scratch_path, "reviews", "RUN-1.json"]), """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "severity": "major", "recommendation": "fix"}
    ]}
    """)

    {_run, os_process} = exited.(:review, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :review} = Repo.reload!(task)
    assert [%{key: "unhandled-nil", decision: nil}] = Pipeline.list_review_findings(task)
  end

  # The process is settled before the stage's finish runs, so a finish that raises
  # would otherwise unwind leaving a run that looks finished, moved nothing and
  # said nothing about why.
  test "a finish that blows up says so on the run", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    File.mkdir_p!(Path.join(task.scratch_path, "reviews"))

    File.write!(Path.join([task.scratch_path, "reviews", "RUN-1.json"]), """
    {"findings": [
      {"key": "too-far", "title": "Past the end of the file", "severity": "major",
       "recommendation": "fix", "line": 99999999999}
    ]}
    """)

    {_run, os_process} = exited.(:review, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: error}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert error =~ "Postgrex expected an integer"
    assert Pipeline.list_review_findings(task) == []
  end

  # The reviewer is argued with after it has reported, and the argument ends in a
  # rewritten report. A latch that stopped Rail reading it would leave the panel
  # showing what the reviewer said two turns ago.
  test "a review run that already reported reads its file again on the next turn", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    File.mkdir_p!(Path.join(task.scratch_path, "reviews"))
    report = Path.join([task.scratch_path, "reviews", "RUN-1.json"])

    File.write!(report, """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "severity": "major", "recommendation": "fix"}
    ]}
    """)

    {run, os_process} = exited.(:review, %{})
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert [%{key: "unhandled-nil", suggestion: nil}] = Pipeline.list_review_findings(task)

    File.write!(report, """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "severity": "major", "recommendation": "fix",
       "suggestion": "Match the empty map first."}
    ]}
    """)

    {:ok, chat_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/run_finished/#{run.id}-chat.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    assert {:ok, %Run{}} = Pipeline.run_finished(chat_process, %{exit_code: 0})

    assert [%{suggestion: "Match the empty map first."}] = Pipeline.list_review_findings(task)
  end

  test "a run at a stage with no finish of its own records itself and moves nothing", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :debugger})
    {_run, os_process} = exited.(:debugger, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :debugger} = Repo.reload!(task)
  end

  test "a QA run records what it found and leaves the task at QA", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa})
    File.mkdir_p!(Path.join(task.scratch_path, "qa"))

    File.write!(Path.join([task.scratch_path, "qa", "RUN-1.json"]), """
    {"verdict": "fail", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5",
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix"}
    ]}
    """)

    {_run, os_process} = exited.(:qa, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :qa} = Repo.reload!(task)
    assert [%{key: "total-unrounded", decision: nil}] = Pipeline.list_qa_findings(task)
  end

  # The demo settles the same way QA does: the recording is encoded, the write-up
  # is read, and the task stays where it is for a human to watch it.
  test "a demo run encodes what it filmed and leaves the task at demo", %{task: task, exited: exited} do
    {:ok, _filming} = Pipeline.update_task(task, %{stage: :demo})
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "RUN-1.json"), ~s({"title": "Filters", "summary": "It filters."}))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    {_run, os_process} = exited.(:demo, %{})

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  test "a QA run that wrote no report says so and stays open", %{task: task, exited: exited} do
    {:ok, _at_qa} = Pipeline.update_task(task, %{stage: :qa})
    {_run, os_process} = exited.(:qa, %{})

    error = "The QA agent did not write qa/RUN-1.json."

    assert {:ok, %Run{stage_outcome: :in_progress, error: ^error}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  # QA is argued with after it has reported, and the argument ends in a rewritten
  # report with a new verdict. A latch that stopped Rail reading it would leave
  # the panel showing what QA said two turns ago.
  test "a QA run that already reported reads its file again on the next turn", %{
    task: task,
    roles: roles,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa})
    File.mkdir_p!(Path.join(task.scratch_path, "qa"))
    report = Path.join([task.scratch_path, "qa", "RUN-1.json"])

    File.write!(report, """
    {"verdict": "fail", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5",
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix"}
    ]}
    """)

    {run, os_process} = exited.(:qa, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert [%{status: :open}] = Pipeline.list_qa_findings(task)

    File.write!(report, """
    {"verdict": "pass", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5",
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix",
       "status": "fixed"}
    ]}
    """)

    {:ok, chat_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        role_id: roles[:qa].id,
        os_pid: 4321,
        stream_path: "/tmp/run_finished/#{run.id}-qa-chat.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    assert {:ok, %Run{}} = Pipeline.run_finished(chat_process, %{exit_code: 0})
    assert [%{status: :fixed}] = Pipeline.list_qa_findings(task)
  end

  # Agy exits non-zero when its root agent stops with background tasks still
  # running, having done the work and written its commit message. Throwing that
  # turn away left the change uncommitted with nothing to move it on.
  test "an engineer that said it was done is taken at its word, whatever the exit code", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))
    File.write!(Path.join([task.scratch_path, "commits", "RUN-1.md"]), "RUN-1: did the work\n")
    File.write!(Path.join(task.worktree_path, "changed.ex"), "the engineer's work\n")

    stub(Git, :push_branch, fn _path, _branch -> :ok end)
    {_run, os_process} = exited.(:engineer, %{})

    assert {:ok, %Run{stage_outcome: :done, error: nil}} =
             Pipeline.run_finished(os_process, %{exit_code: 1, error: "root agent idle; waiting for 2 background task(s)"})

    refute Git.worktree_dirty?(task.worktree_path)
  end

  test "an engineer run that left no commit message stays open for the message that fixes it", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "The engineer did not write commits/RUN-1.md."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # One commit per round, not one per turn: a latched run says nothing more, so the
  # chat turns a human has with it after it finished never commit again.
  test "an engineer run that already had its say does not commit a second time", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{stage_outcome: :done})

    reject(&Git.commit_worktree/3)

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "an architect run that left no plan stays open for the message that fixes it", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :architect})
    {_run, os_process} = exited.(:architect, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "The architect did not write plans/RUN-1.md."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{stage: :architect} = Repo.reload!(task)
  end

  test "an architect run that wrote its plan latches done", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :architect})
    File.mkdir_p!(Path.join(task.scratch_path, "plans"))
    File.write!(Path.join([task.scratch_path, "plans", "RUN-1.md"]), "## Implementation plan\n\nExtend the module.\n")

    {_run, os_process} = exited.(:architect, %{})

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :architect} = Repo.reload!(task)
  end

  test "a product run that left no ticket stays open for the message that fixes it", %{
    task: task,
    exited: exited
  } do
    File.rm!(Path.join([task.scratch_path, "tickets", "RUN-1.md"]))
    {_run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "The product agent did not write tickets/RUN-1.md."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{stage: :product} = Repo.reload!(task)
  end

  test "a design run that left its options incomplete stays open for the message that fixes it", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :design})
    {_run, os_process} = exited.(:design, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "The designer did not write design/manifest.json."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{stage: :design} = Repo.reload!(task)
  end

  test "a design run that wrote three complete options latches done", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :design})
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}, {"key": "c", "title": "C"}]})
    )

    for key <- ["a", "b", "c"] do
      File.write!(Path.join(design_dir, "#{key}.html"), "<p>#{key}</p>")
      File.write!(Path.join(design_dir, "#{key}.png"), "png")
    end

    {_run, os_process} = exited.(:design, %{})

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "an outcome that arrives with string keys settles the same way", %{exited: exited} do
    {_run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{exit_code: 3, error: "It went wrong"}} =
             Pipeline.run_finished(os_process, %{
               "exit_code" => 3,
               "error" => "It went wrong",
               "usage" => %{input_tokens: 4, output_tokens: 2}
             })
  end

  test "an outcome with no exit code settles as a clean exit", %{exited: exited} do
    {_run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{exit_code: 0, usage: %Run.Usage{input_tokens: 4}}} =
             Pipeline.run_finished(os_process, %{usage: %{input_tokens: 4}})
  end

  test "a usage record under a string key is taken as it is", %{exited: exited} do
    {_run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{usage: %Run.Usage{output_tokens: 6}}} =
             Pipeline.run_finished(os_process, %{"exit_code" => 0, "usage" => %Run.Usage{output_tokens: 6}})
  end

  test "a clean exit that still recorded an error stays open", %{exited: exited} do
    {_run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{error: "It went wrong", stage_outcome: :in_progress}} =
             Pipeline.run_finished(os_process, %{exit_code: 0, error: "It went wrong"})
  end

  test "re-settling a process keeps what the run layer already wrote", %{exited: exited} do
    {_run, os_process} = exited.(:product, %{exit_code: 1, error: "Recorded earlier"})

    assert {:ok, %Run{exit_code: 1, error: "Recorded earlier"}} = Pipeline.run_finished(os_process)
  end

  test "a run parked on a question stays parked when its process exits", %{exited: exited} do
    {_run, os_process} = exited.(:product, %{status: :blocked_on_input})

    assert {:ok, %Run{status: :blocked_on_input}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a worktree setup that succeeded marks the worktree set up and enters the stage it held up", %{
    task: task,
    roles: roles,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :debugger, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:debugger, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()
    %{id: debugger_role_id} = roles[:debugger]

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{role_id: ^debugger_role_id, status: :running}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{worktree_setup_at: %DateTime{}} = Repo.reload!(task)
  end

  test "a worktree setup that failed says so on the run and starts nothing", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :debugger})
    {_run, os_process} = exited.(:debugger, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{error: "The worktree setup script failed (Exited with code 1)." <> _rest}} =
             Pipeline.run_finished(os_process, %{exit_code: 1, error: "Exited with code 1"})

    assert %Task{worktree_setup_at: nil} = Repo.reload!(task)
  end

  test "a worktree set up under a conversation already going sends the message that was waiting", %{
    task: task,
    exited: exited
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :debugger, worktree_path: create_temp_git_repo()})
    {run, _agent_process} = exited.(:debugger, %{status: :finished, pending_chat: "Keep going"})

    setup_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        kind: :setup,
        stream_path: "/tmp/run_finished/#{run.id}.log",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    test_pid = self()

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:dispatched, argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.run_finished(setup_process, %{exit_code: 0}, async: false)
    assert_received {:dispatched, argv}
    assert Enum.any?(argv, &(&1 =~ "Keep going"))
  end

  test "a message typed while a new worktree was set up waits for the stage's first turn", %{
    task: task,
    exited: exited
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :debugger, worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:debugger, %{pending_chat: "Also check the logs"})
    os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

    expect(Tools, :start_os_process, fn spawned, argv ->
      refute Enum.any?(argv, &(&1 =~ "Also check the logs"))
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{status: :running}} = Pipeline.run_finished(os_process, %{exit_code: 0}, async: false)
    assert %Run{pending_chat: "Also check the logs"} = Repo.reload!(run)
  end

  test "a worktree set up for a stage the task has since left enters nothing", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    {_run, os_process} = exited.(:debugger, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{status: :finished, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :review, worktree_setup_at: %DateTime{}} = Repo.reload!(task)
  end

  test "an engineer finished on a project with CI commits and starts CI, and is not done until it passes", %{
    project: project,
    task: task,
    exited: exited
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))
    File.write!(Path.join([task.scratch_path, "commits", "RUN-1.md"]), "RUN-1: did the work\n")
    File.write!(Path.join(task.worktree_path, "changed.ex"), "the engineer's work\n")
    head_before = String.trim(git!(task.worktree_path, ["rev-parse", "HEAD"]))

    reject(&Git.push_branch/2)
    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)

    expect(Tools, :start_command_process, fn run, :ci, "mise run ci", opts ->
      assert %{"RAIL_GIT_TOKEN" => "ghs_token"} = opts[:env]
      assert opts[:timeout_ms] == to_timeout(minute: 30)
      assert opts[:head_sha] == String.trim(git!(task.worktree_path, ["rev-parse", "HEAD"]))
      refute opts[:head_sha] == head_before
      {:ok, %OsProcess{kind: :ci, run: run}}
    end)

    {_run, os_process} = exited.(:engineer, %{})

    assert {:ok, %Run{status: :running, stage_outcome: :in_progress, error: nil}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    refute Git.worktree_dirty?(task.worktree_path)
  end

  test "CI that cannot get a credential to push with fails the run on why", %{
    project: project,
    task: task,
    exited: exited
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))
    File.write!(Path.join([task.scratch_path, "commits", "RUN-1.md"]), "RUN-1: did the work\n")
    File.write!(Path.join(task.worktree_path, "changed.ex"), "the engineer's work\n")

    stub(Git, :credential_env, fn _project -> {:error, {:github_api_error, 404, %{}}} end)
    reject(Tools, :start_command_process, 4)
    {_run, os_process} = exited.(:engineer, %{})

    assert {:ok,
            %Run{
              stage_outcome: :in_progress,
              error: "Could not commit the engineer's work: Could not start CI: " <> _reason
            }} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "CI that passed pushes the branch and has the engineer's run done", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    {_run, os_process} = exited.(:engineer, %{ci_failure_streak: 2})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    expect(Git, :push_branch, fn _scope, _task -> :ok end)

    assert {:ok, %Run{stage_outcome: :done, ci_failure_streak: 0, error: nil}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "CI that passed on a branch that will not push says so and is not done", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    {_run, os_process} = exited.(:engineer, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    expect(Git, :push_branch, fn _scope, _task -> {:error, "no CI receipt for this tree"} end)

    assert {:ok,
            %Run{
              stage_outcome: :in_progress,
              error: "CI passed, but the branch could not be pushed: no CI receipt for this tree"
            }} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "CI that failed goes back to the engineer with the end of its output", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:engineer, %{})
    stream_path = Path.join(task.scratch_path, "ci.log")
    File.mkdir_p!(task.scratch_path)
    File.write!(stream_path, Enum.map_join(1..200, "\n", &"line #{&1}") <> "\n\e[31m1 test, 1 failure\e[0m\n")

    os_process =
      os_process |> OsProcess.changeset(%{kind: :ci, command: "mise run ci", stream_path: stream_path}) |> Repo.update!()

    test_pid = self()

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:resumed, Enum.join(argv, " ")})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{status: :running, ci_failure_streak: 1}} =
             Pipeline.run_finished(os_process, %{exit_code: 1, error: "Exited with code 1"})

    assert_received {:resumed, prompt}
    assert prompt =~ "`mise run ci` exited with code 1"
    assert prompt =~ "1 test, 1 failure"
    assert prompt =~ "line 60"
    refute prompt =~ "line 50\n"
    assert prompt =~ "The whole log is #{stream_path}"

    assert [%{line: "[rail] CI failed, so its output went back to the engineer (1 of 3)."}] =
             Pipeline.list_run_events(run)
  end

  test "CI that timed out goes back to the engineer saying so", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    os_process =
      os_process
      |> OsProcess.changeset(%{kind: :ci, command: "mise run ci", stream_path: "/tmp/gone.log"})
      |> Repo.update!()

    expect(Tools, :start_os_process, fn spawned, argv ->
      assert Enum.any?(argv, &(&1 =~ "`mise run ci` timed out and was stopped"))
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{status: :running}} = Pipeline.run_finished(os_process, %{exit_code: 124})
  end

  test "CI that failed a third time in a row waits for a person", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    {_run, os_process} = exited.(:engineer, %{ci_failure_streak: 2})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{status: :finished, ci_failure_streak: 3, error: "CI failed 3 times in a row" <> _rest}} =
             Pipeline.run_finished(os_process, %{exit_code: 1})
  end

  test "CI that was stopped before it finished sends nothing back", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    {_run, os_process} = exited.(:engineer, %{ci_failure_streak: 1})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{ci_failure_streak: 1, error: "CI was stopped before it finished." <> _rest}} =
             Pipeline.run_finished(os_process, %{exit_code: -1})
  end

  test "CI that failed with dispatch off says the engineer was not resumed", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci, command: "mise run ci"}) |> Repo.update!()

    expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert {:ok, %Run{status: :finished, error: "Dispatch is off, so the engineer was not resumed."}} =
             Pipeline.run_finished(os_process, %{exit_code: 1})
  end

  test "CI that failed and could not resume the engineer keeps why", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:engineer, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci, command: "mise run ci"}) |> Repo.update!()

    expect(Tools, :start_os_process, fn spawned, _argv ->
      {:ok, failed} = Pipeline.update_run(spawned, %{status: :failed, error: "Failed to spawn runner: :enoent"})
      {:error, {:spawn_failed, :enoent, failed}}
    end)

    assert {:ok, %Run{error: "Failed to spawn runner: :enoent"}} = Pipeline.run_finished(os_process, %{exit_code: 1})
    assert %Run{ci_failure_streak: 1} = Repo.reload!(run)
  end

  test "CI that passed on a branch GitHub will not give a token for says why", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    {_run, os_process} = exited.(:engineer, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    expect(Git, :push_branch, fn _scope, _task -> {:error, {:github_api_error, 401, %{}}} end)

    assert {:ok, %Run{error: "CI passed, but the branch could not be pushed: {:github_api_error, 401, %{}}"}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end
end
