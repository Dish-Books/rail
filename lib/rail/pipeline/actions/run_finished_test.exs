defmodule Rail.Pipeline.Actions.RunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :demo, :debugger], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

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
    Req.Test.stub(Client, fn conn ->
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

  test "a settled run tells whoever is watching the pipeline", %{task: %Task{id: task_id}, exited: exited} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    {_run, os_process} = exited.(:product, %{})

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a process whose run is gone has nothing to settle", %{task: %Task{id: task_id}, exited: exited} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    {run, os_process} = exited.(:product, %{})
    Repo.delete!(run)

    assert {:error, :invalid_state} = Pipeline.run_finished(os_process)
    refute_received {:pipeline_changed, ^task_id}
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

  test "a question another run left unanswered does not hold this run's finish", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    {engineer_run, _engineer_process} = exited.(:engineer, %{})

    {:ok, _question} =
      Pipeline.register_question(Repo.preload(engineer_run, task: :issue), %DetectedQuestion{prompt: "Rebase onto main?"})

    File.mkdir_p!(Path.join(task.scratch_path, "reviews"))

    File.write!(Path.join([task.scratch_path, "reviews", "RUN-1.json"]), """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "severity": "major", "recommendation": "fix"}
    ]}
    """)

    {_run, os_process} = exited.(:review, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert [%{key: "unhandled-nil"}] = Pipeline.list_review_findings(task)
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
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix",
       "evidence": [{"name": "the total", "kind": "query", "text": "total: 1234.5"}]}
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

  test "a demo that is done takes the task's pull request out of draft", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :demo, pr_number: 7, pr_is_draft: true})
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "RUN-1.json"), ~s({"title": "Filters", "summary": "It filters."}))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7"})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{"pullRequest" => %{"isDraft" => false}}}})
      end
    end)

    {_run, os_process} = exited.(:demo, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :demo, pr_is_draft: false} = Repo.reload!(task)
  end

  test "a recorded demo is posted on the ticket and linked from the pull request", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :demo, pr_number: 7, pr_is_draft: false})
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "RUN-1.json"), ~s({"title": "Filters", "summary": "It filters."}))
    File.write!(Path.join(demo_dir, "demo.webm"), "webm bytes")

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "fileUpload" => %{
            "success" => true,
            "uploadFile" => %{
              "uploadUrl" => "https://uploads.linear.app/put/run-1",
              "assetUrl" => "https://uploads.linear.app/assets/RUN-1-demo.webm",
              "headers" => []
            }
          }
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert {:ok, "webm bytes", conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      comment = "## Demo: Filters\n\nIt filters.\n\n[Watch the demo](https://uploads.linear.app/assets/RUN-1-demo.webm)"
      assert %{"variables" => %{"input" => %{"body" => ^comment}}} = Jason.decode!(body)

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "comment_demo",
              "body" => comment,
              "createdAt" => "2026-09-22T10:00:00.000Z",
              "issue" => %{"id" => "lin_run_finished_1"},
              "botActor" => %{"name" => "Rail"}
            }
          }
        }
      })
    end)

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "body" => "Opened by Rail.\n\n## Demo\n\n[Watch the demo](old)"})

        {"PATCH", "/repos/example/test-seed/pulls/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert %{
                   "body" =>
                     "Opened by Rail.\n\n## Demo\n\n[Watch the demo](https://uploads.linear.app/assets/RUN-1-demo.webm)"
                 } =
                   Jason.decode!(body)

          Req.Test.json(conn, %{"number" => 7})
      end
    end)

    {run, os_process} = exited.(:demo, %{})

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "Could not publish"))
  end

  test "a recorded demo on a task with no pull request goes on the ticket alone", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :demo})
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "RUN-1.json"), ~s({"title": "Filters", "summary": "It filters."}))
    File.write!(Path.join(demo_dir, "demo.webm"), "webm bytes")

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "fileUpload" => %{
            "success" => true,
            "uploadFile" => %{
              "uploadUrl" => "https://uploads.linear.app/put/run-1",
              "assetUrl" => "https://uploads.linear.app/a.webm",
              "headers" => []
            }
          }
        }
      })
    end)

    Req.Test.expect(Rail.Linear, &Plug.Conn.send_resp(&1, 200, ""))

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "comment_demo_2",
              "body" => "## Demo: Filters",
              "createdAt" => "2026-09-22T10:00:00.000Z",
              "issue" => %{"id" => "lin_run_finished_1"},
              "botActor" => %{"name" => "Rail"}
            }
          }
        }
      })
    end)

    Req.Test.stub(Client, fn _conn -> flunk("asked GitHub about a pull request the task does not have") end)

    {run, os_process} = exited.(:demo, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "Could not publish"))
  end

  test "a demo that could not be published says so and is still done", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :demo})
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "RUN-1.json"), ~s({"title": "Filters", "summary": "It filters."}))
    File.write!(Path.join(demo_dir, "demo.webm"), "webm bytes")

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)
    Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"fileUpload" => %{"success" => false}}}))

    {run, os_process} = exited.(:demo, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "[rail] Could not publish the demo:"))
  end

  test "a draft GitHub will not mark ready does not hold the demo back", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :demo, pr_number: 7, pr_is_draft: true})
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "RUN-1.json"), ~s({"title": "Filters", "summary": "It filters."}))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))

    {_run, os_process} = exited.(:demo, %{})

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
           end) =~ "Could not mark example/test-seed#7 ready for review"

    assert %Task{pr_is_draft: true} = Repo.reload!(task)
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
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix",
       "evidence": [{"name": "the total", "kind": "query", "text": "total: 1234.5"}]}
    ]}
    """)

    {run, os_process} = exited.(:qa, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert [%{status: :open}] = Pipeline.list_qa_findings(task)

    File.write!(report, """
    {"verdict": "pass", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5",
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix",
       "status": "fixed", "evidence": [{"name": "the total now", "kind": "query", "text": "total: 1,234.50"}]}
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

  test "an engineer turn at QA that changed files sends the task back to engineer, uncommitted", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa, worktree_path: create_temp_git_repo()})
    %{head_sha: head_sha, content_digest: content_digest} = Git.content_fingerprint(task.worktree_path)

    {run, os_process} =
      exited.(:engineer, %{
        stage_outcome: :done,
        stage_fingerprint_head_sha: head_sha,
        stage_fingerprint_dirty_digest: content_digest
      })

    File.write!(Path.join(task.worktree_path, "asked_for.ex"), "the change\n")
    reject(&Git.commit_worktree/3)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :engineer} = Repo.reload!(task)
    assert %Run{stage_outcome: :done} = Repo.reload!(run)
    assert Git.worktree_dirty?(task.worktree_path)
  end

  test "an engineer turn at demo that only answered leaves the task and its demo where they were", %{
    task: task,
    roles: roles,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :demo, worktree_path: create_temp_git_repo()})
    %{head_sha: head_sha, content_digest: content_digest} = Git.content_fingerprint(task.worktree_path)

    {:ok, demo_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:demo].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    {_run, os_process} =
      exited.(:engineer, %{
        stage_outcome: :done,
        stage_fingerprint_head_sha: head_sha,
        stage_fingerprint_dirty_digest: content_digest
      })

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :demo} = Repo.reload!(task)
    assert %Run{status: :finished, stage_outcome: :done} = Repo.reload!(demo_run)
  end

  # Files a QA or demo agent left behind were there before the turn, so they are
  # not the engineer changing anything.
  test "an engineer turn at demo in a worktree already dirty, left as it was, moves nothing", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :demo, worktree_path: create_temp_git_repo()})
    File.write!(Path.join(task.worktree_path, "qa_leftover.log"), "from QA\n")
    %{head_sha: head_sha, content_digest: content_digest} = Git.content_fingerprint(task.worktree_path)

    {_run, os_process} =
      exited.(:engineer, %{
        stage_outcome: :done,
        stage_fingerprint_head_sha: head_sha,
        stage_fingerprint_dirty_digest: content_digest
      })

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  # `git status` reads " M" before and after, so only the contents say the turn changed code.
  test "an engineer turn at QA that rewrote a file already modified sends the task back to engineer", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa, worktree_path: create_temp_git_repo()})
    File.write!(Path.join(task.worktree_path, "feature.ex"), "committed\n")
    git!(task.worktree_path, ["add", "."])
    git!(task.worktree_path, ["commit", "-m", "the engineer's round"])
    File.write!(Path.join(task.worktree_path, "feature.ex"), "left uncommitted\n")

    # The message queued during the last turn goes out as it ends, stamping the tree.
    {run, os_process} =
      exited.(:engineer, %{stage_outcome: :done, pending_chat: "Make the currency follow the entity"})

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0}, async: false)
    assert %Task{stage: :qa} = Repo.reload!(task)

    File.write!(Path.join(task.worktree_path, "feature.ex"), "follows the entity\n")

    {:ok, turn} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/run_finished/#{run.id}-turn.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    assert {:ok, %Run{}} = Pipeline.run_finished(turn, %{exit_code: 0})
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "an engineer turn with no record of how the tree started moves nothing", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{stage_outcome: :done})
    File.write!(Path.join(task.worktree_path, "unknown.ex"), "when\n")

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :review} = Repo.reload!(task)
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

  # It has been waiting on the human since it stopped to ask, not since a later exit.
  test "a run still parked on a question keeps the time it stopped to ask", %{exited: exited} do
    asked_at = DateTime.shift(DateTime.utc_now(), minute: -3)
    {_run, os_process} = exited.(:product, %{status: :blocked_on_input, completed_at: asked_at})

    assert {:ok, %Run{status: :blocked_on_input, completed_at: ^asked_at}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a run resumed after asking is dated from the turn that finished it", %{exited: exited} do
    asked_at = DateTime.shift(DateTime.utc_now(), minute: -3)
    {_run, os_process} = exited.(:product, %{completed_at: asked_at})

    assert {:ok, %Run{status: :finished, completed_at: completed_at}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert DateTime.diff(completed_at, asked_at, :second) >= 180
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

  describe "an engineer finishing into a machine with no room for its CI" do
    # Another run's sandbox holds all 4 CPUs the test machine has (config/test.exs).
    setup %{project: project, task: task, roles: roles} do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
      File.mkdir_p!(Path.join(task.scratch_path, "commits"))
      File.write!(Path.join([task.scratch_path, "commits", "RUN-1.md"]), "RUN-1: did the work\n")
      File.write!(Path.join(task.worktree_path, "changed.ex"), "the engineer's work\n")
      stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)

      {:ok, other} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:review].id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: task.id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 4,
        reserved_memory_gb: 2
      })

      :ok
    end

    test "stays open while its CI waits in line", %{exited: exited} do
      {run, os_process} = exited.(:engineer, %{})

      assert {:ok, %Run{status: :waiting_for_resources, stage_outcome: :in_progress}} =
               Pipeline.run_finished(os_process, %{exit_code: 0})

      assert [%OsProcess{status: :waiting_for_resources}] = Tools.list_os_processes(run_id: run.id, kind: :ci)
    end

    test "keeps a queued message for after CI rather than starting a turn beside it", %{exited: exited} do
      {run, %OsProcess{id: agent_id} = os_process} = exited.(:engineer, %{pending_chat: "Also tidy the tests"})

      # Inline, so a message sent out would be sent before this returns.
      assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0}, async: false)
      assert %Run{pending_chat: "Also tidy the tests"} = Repo.reload!(run)
      assert [%OsProcess{id: ^agent_id}] = Tools.list_os_processes(run_id: run.id, kind: :agent)
    end

    test "a merge carried on through CI is not done while CI waits in line", %{task: task, exited: exited} do
      {:ok, _task} = Pipeline.update_task(task, %{is_updating_branch: true})
      {_run, os_process} = exited.(:engineer, %{stage_outcome: :done})

      stub(Git, :merge_in_progress?, fn _path -> true end)
      expect(Git, :merge_default_branch, fn _scope, _task -> :ok end)

      assert {:ok, %Run{status: :waiting_for_resources, stage_outcome: :in_progress}} =
               Pipeline.run_finished(os_process, %{exit_code: 0})
    end
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
    {_run, os_process} = exited.(:engineer, %{review_on_ci_pass: true})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    expect(Git, :push_branch, fn _scope, _task -> {:error, "no CI receipt for this tree"} end)

    assert {:ok,
            %Run{
              stage_outcome: :in_progress,
              review_on_ci_pass: false,
              error: "CI passed, but the branch could not be pushed: no CI receipt for this tree"
            }} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "CI that failed goes back to the engineer with the end of its output", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:engineer, %{review_on_ci_pass: true})
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

    assert {:ok, %Run{status: :running, ci_failure_streak: 1, review_on_ci_pass: false}} =
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

  # The fix turn's end compares against how the tree stood when it started, not
  # against whatever an earlier turn left on the run.
  test "CI that failed on a task past engineer stamps how the tree stood for the fix turn", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa, worktree_path: create_temp_git_repo()})

    {run, os_process} =
      exited.(:engineer, %{
        stage_outcome: :done,
        stage_fingerprint_head_sha: "an_earlier_turn",
        stage_fingerprint_dirty_digest: "an_earlier_digest"
      })

    os_process =
      os_process
      |> OsProcess.changeset(%{kind: :ci, command: "mise run ci", stream_path: "/tmp/gone.log"})
      |> Repo.update!()

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    %{head_sha: head_sha, content_digest: content_digest} = Git.content_fingerprint(task.worktree_path)

    assert {:ok, %Run{status: :running}} = Pipeline.run_finished(os_process, %{exit_code: 1})

    assert %Run{stage_fingerprint_head_sha: ^head_sha, stage_fingerprint_dirty_digest: ^content_digest} =
             Repo.reload!(run)
  end

  test "CI that failed resumes the engineer on the prompt merged to the project's .rail/prompts", %{
    project: project,
    task: task,
    exited: exited
  } do
    remote = create_temp_git_repo(prefix: "rail_ci_prompt_remote")
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "From the repo.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    clone = create_temp_git_repo(prefix: "rail_ci_prompt_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])
    {:ok, _project} = Projects.update_project(system_scope(), project, %{clone_path: clone})

    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci, command: "mise run ci"}) |> Repo.update!()

    expect(Tools, :start_os_process, fn spawned, argv ->
      assert ["--append-system-prompt", "From the repo."] in Enum.chunk_every(argv, 2, 1)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{status: :running}} = Pipeline.run_finished(os_process, %{exit_code: 1})
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
    {_run, os_process} = exited.(:engineer, %{ci_failure_streak: 2, review_on_ci_pass: true})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    reject(Tools, :start_os_process, 2)

    assert {:ok,
            %Run{
              status: :finished,
              ci_failure_streak: 3,
              review_on_ci_pass: false,
              error: "CI failed 3 times in a row" <> _rest
            }} =
             Pipeline.run_finished(os_process, %{exit_code: 1})
  end

  test "CI that was stopped before it finished sends nothing back", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    {_run, os_process} = exited.(:engineer, %{ci_failure_streak: 1, review_on_ci_pass: true})
    os_process = os_process |> OsProcess.changeset(%{kind: :ci}) |> Repo.update!()

    reject(Tools, :start_os_process, 2)

    assert {:ok,
            %Run{ci_failure_streak: 1, review_on_ci_pass: false, error: "CI was stopped before it finished." <> _rest}} =
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

  describe "CI that passed on a commit" do
    # Review only takes a branch the remote has, on a commit CI passed, so the
    # worktree is one CI's pass can really push.
    setup %{project: project, task: task} do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

      remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
      git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
      repo = create_temp_git_repo()
      git!(repo, ["remote", "add", "origin", remote])
      git!(repo, ["push", "--set-upstream", "origin", "main"])
      File.write!(Path.join(repo, "feature.ex"), "the engineer's work\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "the engineer's work"])

      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: repo})

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        git!(path, ["push", "origin", "HEAD"])
        :ok
      end)

      %{task: task, repo: repo, ci: %{kind: :ci, exit_code: 0, head_sha: String.trim(git!(repo, ["rev-parse", "HEAD"]))}}
    end

    test "a human asked for goes on to review with nobody clicking", %{task: task, exited: exited, ci: ci} do
      {_run, os_process} = exited.(:engineer, %{review_on_ci_pass: true})
      os_process = os_process |> OsProcess.changeset(ci) |> Repo.update!()

      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, %Run{stage_outcome: :done, review_on_ci_pass: false}} =
               Pipeline.run_finished(os_process, %{exit_code: 0})

      assert %Task{stage: :review} = Repo.reload!(task)
    end

    # Rail's own commit at the end of a round waits for a human to read the diff.
    test "Rail made on its own stays in engineer", %{task: task, exited: exited, ci: ci} do
      {_run, os_process} = exited.(:engineer, %{})
      os_process = os_process |> OsProcess.changeset(ci) |> Repo.update!()

      reject(Tools, :start_os_process, 2)

      assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a human asked for, with work left uncommitted since, stays in engineer and says why", %{
      task: task,
      repo: repo,
      exited: exited,
      ci: ci
    } do
      {run, os_process} = exited.(:engineer, %{review_on_ci_pass: true})
      os_process = os_process |> OsProcess.changeset(ci) |> Repo.update!()
      File.write!(Path.join(repo, "later.ex"), "written since\n")

      reject(Tools, :start_os_process, 2)

      assert {:ok, %Run{stage_outcome: :done, review_on_ci_pass: false}} =
               Pipeline.run_finished(os_process, %{exit_code: 0})

      assert %Task{stage: :engineer} = Repo.reload!(task)

      assert [%{line: "[rail] CI passed, but the work was not sent to review: " <> _reason}] =
               Pipeline.list_run_events(run)
    end

    # A message queued while CI ran is the engineer about to work again.
    test "a human asked for, with a message queued meanwhile, sends the engineer that instead", %{
      task: task,
      exited: exited,
      ci: ci
    } do
      {_run, os_process} = exited.(:engineer, %{review_on_ci_pass: true, pending_chat: "Rename the filter too"})
      os_process = os_process |> OsProcess.changeset(ci) |> Repo.update!()
      test_pid = self()

      expect(Tools, :start_os_process, fn spawned, argv ->
        send(test_pid, {:dispatched, Enum.join(argv, " ")})
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{review_on_ci_pass: false}} =
               Pipeline.run_finished(os_process, %{exit_code: 0}, async: false)

      assert %Task{stage: :engineer} = Repo.reload!(task)
      assert_received {:dispatched, prompt}
      assert prompt =~ "Rename the filter too"
    end
  end

  # The conflicts already sent the task back to engineer, and finishing the merge
  # leaves it there for review to see the result.
  test "conflicts the engineer resolved are carried on and the branch sent on", %{task: task, exited: exited} do
    {:ok, task} =
      Pipeline.update_task(task, %{stage: :engineer, is_updating_branch: true, worktree_path: create_temp_git_repo()})

    {_run, os_process} = exited.(:engineer, %{stage_outcome: :done})

    stub(Git, :merge_in_progress?, fn _path -> true end)

    expect(Git, :merge_default_branch, fn _scope, _task ->
      git!(task.worktree_path, ["commit", "--allow-empty", "-m", "merged main in"])
      :ok
    end)

    expect(Git, :push_branch, fn _scope, _task -> :ok end)

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{is_updating_branch: false, stage: :engineer} = Repo.reload!(task)
  end

  test "a merge carried on through CI is not done until CI passes", %{project: project, task: task, exited: exited} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _task} = Pipeline.update_task(task, %{is_updating_branch: true, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{stage_outcome: :done})

    stub(Git, :merge_in_progress?, fn _path -> true end)
    expect(Git, :merge_default_branch, fn _scope, _task -> :ok end)
    reject(&Git.push_branch/2)
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)
    expect(Tools, :start_command_process, fn run, :ci, "mise run ci", _opts -> {:ok, %OsProcess{kind: :ci, run: run}} end)

    assert {:ok, %Run{status: :running, stage_outcome: :in_progress}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a merge that stops on conflicts again goes back to the engineer", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{is_updating_branch: true, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    stub(Git, :merge_in_progress?, fn _path -> true end)
    expect(Git, :merge_default_branch, fn _scope, _task -> {:conflicts, ["lib/next.ex"]} end)

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "- lib/next.ex"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{status: :running}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "an engineer that stopped with conflicts unresolved stays updating the branch", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{is_updating_branch: true, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    stub(Git, :conflicted_files, fn _path -> ["lib/app.ex"] end)
    reject(&Git.merge_default_branch/2)

    assert {:ok, %Run{error: "The engineer stopped with conflicts still unresolved." <> _rest}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{is_updating_branch: true} = Repo.reload!(task)
  end

  test "a merge the engineer abandoned is said so", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{is_updating_branch: true, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    stub(Git, :merge_in_progress?, fn _path -> false end)
    stub(Git, :up_to_date_with?, fn _path, "main" -> false end)

    assert {:ok, %Run{error: "The merge of origin/main was abandoned before it finished." <> _rest}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a merge that cannot be carried on says why", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{is_updating_branch: true, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    stub(Git, :merge_in_progress?, fn _path -> true end)
    expect(Git, :merge_default_branch, fn _scope, _task -> {:error, {:github_api_error, 401, %{}}} end)

    assert {:ok, %Run{error: "The merge could not be finished: {:github_api_error, 401, %{}}"}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a merge carried on whose push fails says why", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{is_updating_branch: true, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    stub(Git, :merge_in_progress?, fn _path -> true end)
    expect(Git, :merge_default_branch, fn _scope, _task -> :ok end)
    expect(Git, :push_branch, fn _scope, _task -> {:error, "! [rejected] (stale info)"} end)

    assert {:ok, %Run{error: "The merge could not be finished: ! [rejected] (stale info)"}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "an engineer that asks something while updating the branch parks on it", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{is_updating_branch: true})
    {run, os_process} = exited.(:engineer, %{})
    now = DateTime.utc_now()

    Repo.insert_all(RunEvent, [
      %{
        id: UXID.generate!(),
        run_id: run.id,
        os_process_id: os_process.id,
        line: "[QUESTION: Keep both migrations?]",
        inserted_at: now,
        updated_at: now
      }
    ])

    reject(&Git.merge_default_branch/2)

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert [%{prompt: "Keep both migrations?"}] = pending_questions(task.id)
  end

  describe "a round Rail answered from past answers" do
    setup %{project: project} do
      earlier = learnings_task(project, "RFG-1")
      past = %Question{id: "qst_rfg_past", prompt: "Postgres or SQLite?", answer: "Postgres.", status: :answered}
      {:ok, [rule]} = Rail.Learnings.record_corrections(earlier, [past])

      Repo.update_all(from(l in Rail.Learnings.Schemas.Learning, where: l.id == ^rule.id),
        set: [embedding: Pgvector.new(vector([1.0])), embedding_model: "gemini-embedding-001"]
      )

      stub_vertex(%{"Which database" => vector([1.0, 0.1])})

      asked = fn run, os_process, prompts ->
        now = DateTime.utc_now()

        Repo.insert_all(
          RunEvent,
          for prompt <- prompts do
            %{
              id: UXID.generate!(),
              run_id: run.id,
              os_process_id: os_process.id,
              line: "[QUESTION: #{prompt}]",
              inserted_at: now,
              updated_at: now
            }
          end
        )
      end

      %{asked: asked}
    end

    test "is sent at once and the run carries on without a person", %{task: task, exited: exited, asked: asked} do
      {run, os_process} = exited.(:product, %{})
      asked.(run, os_process, ["Which database?"])

      assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})

      assert [%Question{answered_by_rail: true, delivered_at: %DateTime{}}] =
               Repo.all(from q in Question, where: q.task_id == ^task.id)

      lines = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
      assert "[answered from past answers] You asked: Which database?" in lines

      assert Enum.any?(
               lines,
               &(&1 =~ ~s([answered from past answers] Answered by Rail from Rail's answer on RFG-1, ) and
                   String.ends_with?(&1, ": Postgres."))
             )

      refute Enum.any?(lines, &String.starts_with?(&1, "[human]"))
      refute Enum.any?(lines, &(&1 =~ "When asked"))
    end

    test "waits while a person still has a question to answer", %{task: task, exited: exited, asked: asked} do
      {run, os_process} = exited.(:product, %{})
      asked.(run, os_process, ["Which database?", "Ship behind a flag?"])

      assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})

      assert %Run{status: :blocked_on_input} = Repo.reload!(run)

      assert [%Question{answered_by_rail: true, delivered_at: nil}, %Question{status: :pending}] =
               Repo.all(from q in Question, where: q.task_id == ^task.id, order_by: [asc: q.inserted_at, asc: q.id])
    end

    test "waits on a turn a person stopped, rather than resuming it", %{task: task, exited: exited, asked: asked} do
      {run, os_process} = exited.(:product, %{})
      asked.(run, os_process, ["Which database?"])
      {:ok, os_process} = os_process |> Ecto.Changeset.change(ended_reason: :stopped) |> Repo.update()
      reject(&Tools.start_os_process/2)

      assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})

      assert [%Question{answered_by_rail: true, delivered_at: nil}] =
               Repo.all(from q in Question, where: q.task_id == ^task.id)
    end
  end
end
