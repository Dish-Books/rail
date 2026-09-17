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
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead], fn stage ->
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
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {run, os_process}
    end

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
        node: to_string(Node.self()),
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
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa_lead})
    {_run, os_process} = exited.(:qa_lead, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :qa_lead} = Repo.reload!(task)
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
        node: to_string(Node.self()),
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
end
