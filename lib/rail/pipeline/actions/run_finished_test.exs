defmodule Rail.Pipeline.Actions.RunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.BrowserSession
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    roles =
      Map.new([:plan, :engineer, :qa, :review_lead, :demo], fn stage ->
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
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # Plan checks that its agent left a ticket and a plan behind, so a run meant to
    # read as clean needs both there.
    Repo.insert!(%Round{
      task_id: task.id,
      number: 1,
      plan: "## Implementation plan\n\nExtend the module.",
      ticket: %Round.Ticket{title: "Run Finished Issue", description: "Body."}
    })

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
    {run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{status: :finished, exit_code: 0, completed_at: %DateTime{}}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %OsProcess{status: :finished} = Repo.reload!(os_process)
    assert %Run{status: :finished} = Repo.reload!(run)
  end

  test "usage accumulates across the processes a run is carried by", %{exited: exited} do
    {run, os_process} = exited.(:plan, %{usage: %Run.Usage{input_tokens: 10, output_tokens: 5}})

    {:ok, _run} =
      Pipeline.run_finished(os_process, %{
        exit_code: 0,
        usage: %Run.Usage{input_tokens: 1, output_tokens: 2}
      })

    assert %Run{usage: %Run.Usage{input_tokens: 11, output_tokens: 7}} = Repo.reload!(run)
  end

  test "a non-zero exit records the error and concludes nothing", %{task: task, exited: exited} do
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{exit_code: 2, error: "Exited with code 2", stage_outcome: :in_progress}} =
             Pipeline.run_finished(os_process, %{exit_code: 2, error: "Exited with code 2"})

    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "a settled run tells whoever is watching the pipeline", %{task: %Task{id: task_id}, exited: exited} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a process whose run is gone has nothing to settle", %{task: %Task{id: task_id}, exited: exited} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    {run, os_process} = exited.(:plan, %{})
    Repo.delete!(run)

    assert {:error, :invalid_state} = Pipeline.run_finished(os_process)
    refute_received {:pipeline_changed, ^task_id}
  end

  test "a message queued while the run worked goes out once it is idle", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:plan, %{pending_chat: "Please also add a test"})

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
    {run, os_process} = exited.(:plan, %{})

    Pipeline.append_run_events(run.id, nil, ["The ticket is written."])

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})

    # Plan hands on only when a human approves; the exit itself moves nothing.
    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "a run that already had its say is left alone however often it exits", %{task: task, exited: exited} do
    {run, os_process} = exited.(:plan, %{stage_outcome: :done})

    Pipeline.append_run_events(run.id, nil, ["Still done."])

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "a run that asked something parks on it rather than concluding", %{task: task, exited: exited} do
    {run, os_process} = exited.(:plan, %{})
    {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])

    assert {:ok, %Run{stage_outcome: :in_progress}} = Pipeline.run_finished(os_process, %{exit_code: 0})

    assert [%{prompt: "Which database?"}] = pending_questions(task.id)
  end

  test "a review agent turn that saved its review leaves the task at review with what it found", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})

    {:ok, _finding} =
      Pipeline.save_finding(task, %{
        key: "unhandled-nil",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Nil is not handled",
        problem: "A task with no worktree crashes the page.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard the nil in the action.",
        why: "It crashes.",
        rule: "Every caller handles a missing worktree.",
        severity: :major,
        recommendation: :skip,
        places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}],
        evidence: [%{name: "The clause", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, _pass} = Pipeline.save_review(task)

    {_run, os_process} = exited.(:review_lead, %{})

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :review} = Repo.reload!(task)
    assert [%{key: "unhandled-nil", decision: nil}] = Pipeline.list_findings(task)
  end

  # A turn that is over drives no browser, and every tab kept is memory the shared Chrome's other tabs need.
  test "a QA turn that ends closes its own browser and leaves the others open", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})

    for name <- ["qa", "demo"] do
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: name, status: :running})
      |> Repo.insert!()
    end

    {_run, os_process} = exited.(:qa, %{})

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 1, error: "stopped"})

    assert [
             %BrowserSession{name: "demo", status: :running},
             %BrowserSession{name: "qa", status: :finished, ended_reason: :closed}
           ] = Repo.all(from s in BrowserSession, where: s.task_id == ^task.id, order_by: s.name)
  end

  # The code reviewer started beside QA, so QA's finish starts nothing while it works.
  test "a QA turn that saved its report latches done and starts nothing while the other checks work", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})
    {:ok, _saved} = Pipeline.save_report(task, :qa, "Two rows.")
    {_run, os_process} = exited.(:qa, %{})
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a review agent turn that did not save its review says so and stays open", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :review})
    {_run, os_process} = exited.(:review_lead, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "The review agent did not save its review."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a question another run left unanswered does not hold this run's finish", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    {engineer_run, _engineer_process} = exited.(:engineer, %{})

    Repo.insert!(%Question{task_id: engineer_run.task_id, run_id: engineer_run.id, prompt: "Rebase onto main?"})

    {:ok, _finding} =
      Pipeline.save_finding(task, %{
        key: "unhandled-nil",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Nil is not handled",
        problem: "A task with no worktree crashes the page.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard the nil in the action.",
        why: "It crashes.",
        rule: "Every caller handles a missing worktree.",
        severity: :major,
        recommendation: :skip,
        places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}],
        evidence: [%{name: "The clause", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, _pass} = Pipeline.save_review(task)

    {_run, os_process} = exited.(:review_lead, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  # The process is settled before the stage's finish runs, so a finish that raises
  # would otherwise unwind leaving a run that looks finished, moved nothing and
  # said nothing about why.
  test "a finish that blows up says so on the run", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})
    {:ok, _pass} = Pipeline.save_review(task)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    stub(Git, :branch_fingerprint, fn _path -> raise "git fell over" end)

    {_run, os_process} = exited.(:review_lead, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "git fell over"}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a run at a stage with no finish of its own records itself and moves nothing", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    {_run, os_process} = exited.(:demo, %{})

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "an engineer turn stopped part way hands nothing over", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    reject(&Pipeline.hand_over_work/2)

    assert {:ok, %Run{stage_outcome: :in_progress, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: -1})
  end

  test "an engineer turn that committed nothing new stays open for the turn that does", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{})

    stub(Git, :branch_unpushed?, fn _path -> false end)
    reject(&Pipeline.hand_over_work/2)

    assert {:ok, %Run{stage_outcome: :in_progress, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "an engineer turn that committed hands its commits over and has its say", %{task: task, exited: exited} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {%Run{id: run_id}, os_process} = exited.(:engineer, %{})

    expect(Pipeline, :hand_over_work, fn _scope, %Run{id: ^run_id} = run -> {:ok, run} end)

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  # What the turn left uncommitted is not sent on, so it is said rather than lost.
  test "an engineer turn says what it left uncommitted", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    File.write!(Path.join(task.worktree_path, "tracked.txt"), "changed\n")
    {run, os_process} = exited.(:engineer, %{})

    stub(Git, :branch_unpushed?, fn _path -> false end)

    assert {:ok, %Run{stage_outcome: :in_progress, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})

    assert [%{line: "[rail] This turn left uncommitted changes in the worktree." <> _rest}] =
             Pipeline.list_run_events(run)
  end

  # One hand-over per round, not one per turn: a latched run says nothing more, so the
  # chat turns a human has with it after it finished never send anything on again.
  test "an engineer run that already had its say does not hand over a second time", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{stage_outcome: :done})

    reject(&Pipeline.hand_over_work/2)

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # Past Engineer the round is the checking agents', so an engineer turn there leaves the task where it is.
  test "an engineer turn after the task left Engineer moves nothing, whatever it changed", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:engineer, %{stage_outcome: :done})
    File.write!(Path.join(task.worktree_path, "unknown.ex"), "when\n")

    reject(&Pipeline.hand_over_work/2)

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a Plan run that left no plan stays open for the message that fixes it", %{task: task, exited: exited} do
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "The Plan agent did not save a plan."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "a Plan run that left no ticket stays open for the message that fixes it", %{task: task, exited: exited} do
    Repo.delete_all(from(r in Round, where: r.task_id == ^task.id))
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{stage_outcome: :in_progress, error: "The Plan agent did not save a ticket."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a Plan run that left two options and no pick stays open for the message that fixes it", %{
    task: task,
    exited: exited
  } do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}]})
    )

    {_run, os_process} = exited.(:plan, %{})

    assert {:ok,
            %Run{stage_outcome: :in_progress, error: "The Plan agent saved 2 design options. It needs 3, or a pick."}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a Plan run that wrote its ticket, three complete options and its plan latches done", %{
    task: task,
    exited: exited
  } do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}, {"key": "c", "title": "C"}]})
    )

    for key <- ["a", "b", "c"] do
      File.write!(Path.join(design_dir, "#{key}.html"), "<p>#{key}</p>")
      File.write!(Path.join(design_dir, "#{key}.png"), "png")
    end

    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "an outcome that arrives with string keys settles the same way", %{exited: exited} do
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{exit_code: 3, error: "It went wrong"}} =
             Pipeline.run_finished(os_process, %{
               "exit_code" => 3,
               "error" => "It went wrong",
               "usage" => %{input_tokens: 4, output_tokens: 2}
             })
  end

  test "an outcome with no exit code settles as a clean exit", %{exited: exited} do
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{exit_code: 0, usage: %Run.Usage{input_tokens: 4}}} =
             Pipeline.run_finished(os_process, %{usage: %{input_tokens: 4}})
  end

  test "a usage record under a string key is taken as it is", %{exited: exited} do
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{usage: %Run.Usage{output_tokens: 6}}} =
             Pipeline.run_finished(os_process, %{"exit_code" => 0, "usage" => %Run.Usage{output_tokens: 6}})
  end

  test "a clean exit that still recorded an error stays open", %{exited: exited} do
    {_run, os_process} = exited.(:plan, %{})

    assert {:ok, %Run{error: "It went wrong", stage_outcome: :in_progress}} =
             Pipeline.run_finished(os_process, %{exit_code: 0, error: "It went wrong"})
  end

  test "re-settling a process keeps what the run layer already wrote", %{exited: exited} do
    {_run, os_process} = exited.(:plan, %{exit_code: 1, error: "Recorded earlier"})

    assert {:ok, %Run{exit_code: 1, error: "Recorded earlier"}} = Pipeline.run_finished(os_process)
  end

  test "a run parked on a question stays parked when its process exits", %{exited: exited} do
    {_run, os_process} = exited.(:plan, %{status: :blocked_on_input})

    assert {:ok, %Run{status: :blocked_on_input}} = Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  # It has been waiting on the human since it stopped to ask, not since a later exit.
  test "a run still parked on a question keeps the time it stopped to ask", %{exited: exited} do
    asked_at = DateTime.shift(DateTime.utc_now(), minute: -3)
    {_run, os_process} = exited.(:plan, %{status: :blocked_on_input, completed_at: asked_at})

    assert {:ok, %Run{status: :blocked_on_input, completed_at: ^asked_at}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})
  end

  test "a run resumed after asking is dated from the turn that finished it", %{exited: exited} do
    asked_at = DateTime.shift(DateTime.utc_now(), minute: -3)
    {_run, os_process} = exited.(:plan, %{completed_at: asked_at})

    assert {:ok, %Run{status: :finished, completed_at: completed_at}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert DateTime.diff(completed_at, asked_at, :second) >= 180
  end

  test "a worktree setup that succeeded marks the worktree set up and enters the stage it held up", %{
    task: task,
    roles: roles,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :plan, worktree_path: create_temp_git_repo()})
    {_run, os_process} = exited.(:plan, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()
    %{id: plan_role_id} = roles[:plan]

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{role_id: ^plan_role_id, status: :running}} =
             Pipeline.run_finished(os_process, %{exit_code: 0})

    assert %Task{worktree_setup_at: %DateTime{}} = Repo.reload!(task)
  end

  test "a worktree setup that failed says so on the run and starts nothing", %{task: task, exited: exited} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :plan})
    {_run, os_process} = exited.(:plan, %{})
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
    {:ok, _task} = Pipeline.update_task(task, %{stage: :plan, worktree_path: create_temp_git_repo()})
    {run, _agent_process} = exited.(:plan, %{status: :finished, pending_chat: "Keep going"})

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
    {:ok, _task} = Pipeline.update_task(task, %{stage: :plan, worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:plan, %{pending_chat: "Also check the logs"})
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
    {_run, os_process} = exited.(:plan, %{})
    os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{status: :finished, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert %Task{stage: :review, worktree_setup_at: %DateTime{}} = Repo.reload!(task)
  end

  describe "a worktree setup on a project with a .env" do
    # A clone of its own, since a .env in the shared project's would reach other tests' worktrees.
    setup %{task: task} do
      clone = create_temp_git_repo(prefix: "rail_setup_env_clone")
      File.write!(Path.join(clone, ".env"), "FOO=bar\n")
      unique = System.unique_integer([:positive])

      {:ok, %Project{id: project_id}} =
        Projects.create_project(system_scope(), %{
          name: "Setup Env",
          github_repo: "example/setup-env-#{unique}",
          github_installation_id: 1,
          key: "senv#{unique}",
          default_branch: "main",
          clone_path: clone,
          worktree_setup_script: "scripts/setup.sh"
        })

      worktree = create_temp_git_repo(prefix: "rail_setup_env_worktree")
      {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: worktree})
      Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [project_id: project_id])

      %{worktree: worktree}
    end

    test "that succeeded leaves the clone's lines in the worktree's .env", %{worktree: worktree, exited: exited} do
      {_run, os_process} = exited.(:plan, %{})
      os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

      assert {:ok, %Run{status: :finished, error: nil}} = Pipeline.run_finished(os_process, %{exit_code: 0})
      assert File.read!(Path.join(worktree, ".env")) =~ "\nFOO=bar\n"
    end

    test "that failed leaves the worktree with no .env", %{worktree: worktree, exited: exited} do
      {_run, os_process} = exited.(:plan, %{})
      os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

      assert {:ok, %Run{error: "The worktree setup script failed" <> _rest}} =
               Pipeline.run_finished(os_process, %{exit_code: 1, error: "Exited with code 1"})

      refute File.exists?(Path.join(worktree, ".env"))
    end

    test "whose .env cannot be written fails, is not set up, and enters no stage", %{
      task: task,
      worktree: worktree,
      exited: exited
    } do
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})
      File.mkdir_p!(Path.join(worktree, ".env"))
      {%Run{id: setup_run_id}, os_process} = exited.(:engineer, %{})
      os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

      reject(Tools, :start_os_process, 2)

      assert {:ok, %Run{error: "Rail could not write the project's .env into the worktree (" <> _rest}} =
               Pipeline.run_finished(os_process, %{exit_code: 0})

      assert %Task{worktree_setup_at: nil} = Repo.reload!(task)
      assert [%Run{id: ^setup_run_id}] = Repo.all(from(r in Run, where: r.task_id == ^task.id))
    end

    test "whose .env cannot be written keeps a message queued during it, and starts nothing", %{
      task: task,
      worktree: worktree,
      exited: exited
    } do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
      File.mkdir_p!(Path.join(worktree, ".env"))
      {run, os_process} = exited.(:engineer, %{pending_chat: "Also check the logs"})
      os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

      reject(Tools, :start_command_process, 4)
      reject(Tools, :start_os_process, 2)

      assert {:ok, %Run{error: "Rail could not write the project's .env into the worktree" <> _rest}} =
               Pipeline.run_finished(os_process, %{exit_code: 0}, async: false)

      assert %Run{pending_chat: "Also check the logs"} = Repo.reload!(run)
    end

    test "that failed keeps a message queued during it, and starts nothing", %{task: task, exited: exited} do
      {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
      {run, os_process} = exited.(:engineer, %{pending_chat: "Also check the logs"})
      os_process = os_process |> OsProcess.changeset(%{kind: :setup}) |> Repo.update!()

      reject(Tools, :start_command_process, 4)
      reject(Tools, :start_os_process, 2)

      assert {:ok, %Run{error: "The worktree setup script failed" <> _rest}} =
               Pipeline.run_finished(os_process, %{exit_code: 1, error: "Exited with code 1"}, async: false)

      assert %Run{pending_chat: "Also check the logs"} = Repo.reload!(run)
    end
  end

  describe "an engineer hand-over into a machine with no room for its CI" do
    # Another run's sandbox holds all 4 CPUs the test machine has (config/test.exs).
    setup %{project: project, task: task, roles: roles} do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
      stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)

      {:ok, other} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:review_lead].id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      Repo.insert!(%OsProcess{
        run_id: other.id,
        task_id: task.id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 4
      })

      :ok
    end

    test "is not done while CI waits in line", %{exited: exited} do
      {_run, os_process} = exited.(:engineer, %{})

      assert {:ok, %Run{status: :waiting_for_resources, stage_outcome: :in_progress}} =
               Pipeline.run_finished(os_process, %{exit_code: 0})
    end
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
    assert prompt =~ "Fix what it reports and commit the fix."
    assert prompt =~ "A failure your change did not cause is still yours to clear"
    assert prompt =~ "merge it in when it has the fix, and otherwise fix the failing test or code here"
    assert prompt =~ "Never end the turn with nothing changed"

    assert [%{line: "[rail] CI failed, so its output went back to the engineer (1 of 3)."}] =
             Pipeline.list_run_events(run)
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
      test_pid = self()

      # Review opens on QA and the code reviewer together.
      expect(Tools, :start_os_process, 2, fn spawned, _argv ->
        send(test_pid, {:spawned, Repo.preload(spawned, :role, force: true).role.stage})
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{stage_outcome: :done, review_on_ci_pass: false}} =
               Pipeline.run_finished(os_process, %{exit_code: 0})

      assert %Task{stage: :review} = Repo.reload!(task)
      assert_received {:spawned, :qa}
      assert_received {:spawned, :review}
    end

    # CI a person ran from the diff asked for no review, so the work waits for them to send it.
    test "nobody asked to review stays in engineer", %{task: task, exited: exited, ci: ci} do
      {_run, os_process} = exited.(:engineer, %{})
      os_process = os_process |> OsProcess.changeset(ci) |> Repo.update!()

      reject(Tools, :start_os_process, 2)

      assert {:ok, %Run{stage_outcome: :done}} = Pipeline.run_finished(os_process, %{exit_code: 0})
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a human asked for, with a commit made since CI ran, stays in engineer and says why", %{
      task: task,
      repo: repo,
      exited: exited,
      ci: ci
    } do
      {run, os_process} = exited.(:engineer, %{review_on_ci_pass: true})
      os_process = os_process |> OsProcess.changeset(ci) |> Repo.update!()
      git!(repo, ["commit", "--allow-empty", "-m", "committed since"])

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

  test "an engineer that committed and asks something parks on it rather than handing over", %{
    task: task,
    exited: exited
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    {run, os_process} = exited.(:engineer, %{})
    {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Keep both migrations?"}])

    reject(&Pipeline.hand_over_work/2)

    assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})
    assert [%{prompt: "Keep both migrations?"}] = pending_questions(task.id)
  end

  describe "a review agent an earlier round latched, then messaged" do
    setup %{task: task, roles: roles} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})

      {:ok, %Run{id: run_id} = run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:review_lead].id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_run_finished_latched",
          started_at: DateTime.utc_now()
        })

      test_pid = self()
      # Review takes a branch the engineer's hand-over pushed, so these turns have nothing to send on.
      stub(Git, :branch_unpushed?, fn _path -> false end)

      # The turn the message starts is a real process, so its exit can be settled.
      stub(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, _argv ->
        os_process =
          %OsProcess{}
          |> OsProcess.changeset(%{
            run_id: run_id,
            task_id: spawned.task_id,
            stream_path: "/tmp/run_finished/#{run_id}.ndjson",
            status: :running,
            started_at: DateTime.utc_now()
          })
          |> Repo.insert!()

        send(test_pid, {:spawned, os_process})
        {:ok, os_process}
      end)

      %{task: task, run: run}
    end

    test "ends without saving its review and reads failed with that error", %{run: run} do
      {:ok, :sent, %Run{}} = Pipeline.send_message(system_scope(), run, "Are you sure about the nil?")
      assert_receive {:spawned, os_process}

      assert {:ok, %Run{stage_outcome: :in_progress, error: "The review agent did not save its review."} = failed} =
               Pipeline.run_finished(os_process, %{exit_code: 0})

      assert :failed = failed |> Repo.preload(:questions, force: true) |> Run.state()
    end

    test "asks a question after a saved round and reads blocked, stopped or not", %{task: task, run: run} do
      {:ok, _pass} = Pipeline.save_review(Repo.preload(task, :issue))
      {:ok, :sent, %Run{}} = Pipeline.send_message(system_scope(), run, "Are you sure about the nil?")
      assert_receive {:spawned, os_process}
      {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Keep the guard?"}])

      assert {:ok, %Run{} = asked} = Pipeline.run_finished(os_process, %{exit_code: 0})
      assert :blocked = asked |> Repo.preload(:questions, force: true) |> Run.state()

      {:ok, stopped, nil} = Pipeline.stop_run(system_scope(), asked)
      assert %Run{status: :finished} = stopped
      assert :blocked = stopped |> Repo.preload(:questions, force: true) |> Run.state()
    end
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
      :ok
    end

    test "is sent at once and the run carries on without a person", %{task: task, exited: exited} do
      {run, os_process} = exited.(:plan, %{})
      {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])

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

    test "waits while a person still has a question to answer", %{task: task, exited: exited} do
      {run, os_process} = exited.(:plan, %{})

      {:ok, _asked} =
        Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}, %{"prompt" => "Ship behind a flag?"}])

      assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})

      assert %Run{status: :blocked_on_input} = Repo.reload!(run)

      assert [%Question{answered_by_rail: true, delivered_at: nil}, %Question{status: :pending}] =
               Repo.all(from q in Question, where: q.task_id == ^task.id, order_by: [asc: q.inserted_at, asc: q.id])
    end

    test "waits on a turn a person stopped, rather than resuming it", %{task: task, exited: exited} do
      {run, os_process} = exited.(:plan, %{})
      {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])
      {:ok, os_process} = os_process |> Ecto.Changeset.change(ended_reason: :stopped) |> Repo.update()
      reject(&Tools.start_os_process/2)

      assert {:ok, %Run{}} = Pipeline.run_finished(os_process, %{exit_code: 0})

      assert [%Question{answered_by_rail: true, delivered_at: nil}] =
               Repo.all(from q in Question, where: q.task_id == ^task.id)
    end
  end
end
