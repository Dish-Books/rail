defmodule Rail.Pipeline.Actions.EndTurnAndCommitTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_etc_1", "identifier" => "ETC-1", "title" => "End Turn Commit"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "End Turn Commit"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    # Review only takes a branch the remote has, so a pushed commit really reaches one.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "--set-upstream", "origin", "main"])
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_end_turn_commit",
        started_at: DateTime.utc_now()
      })

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/end_turn_commit/#{run.id}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Req.Test.stub(Rail.GitHub.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", _pulls} -> Req.Test.json(conn, [])
        {"POST", _pulls} -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 7, "draft" => true})
      end
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    %{task: task, run: run, repo: repo, os_process: os_process}
  end

  test "an accepted commit stops the turn, then commits under the agent's words and pushes", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: %OsProcess{id: os_process_id} = os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    test_pid = self()

    expect(Tools, :stop_os_process, fn _scope, %OsProcess{id: ^os_process_id}, opts ->
      assert opts[:ended_reason] == :handed_over
      send(test_pid, :stopped)
      {:ok, os_process}
    end)

    expect(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
      git!(path, ["push", "origin", "HEAD"])
      :ok
    end)

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :committing} =
             Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature\n\nWhy it changed."})

    assert_received :stopped
    assert_receive {:run_changed, ^run_id}, 5_000

    assert git!(repo, ["log", "-1", "--pretty=%B"]) =~ ~r/\AETC-1: add the feature\n\nWhy it changed.\n\nTicket: ETC-1/
    assert %Run{status: :finished, stage_outcome: :done, error: nil} = Repo.get!(Run, run_id)
    refute File.exists?(Path.join(task.scratch_path, "commits"))
  end

  # The engineer's commit is its word that the work is ready, so a pushed commit goes on to Review.
  test "a commit pushed with no CI sends the task on to Review", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)

    stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
      git!(path, ["push", "origin", "HEAD"])
      :ok
    end)

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Task{stage: :review} = Repo.reload!(task)
  end

  # The agent's CLI can send one call twice, the second while the first is still
  # ending the turn; the stop marks the row finished, as the real one does.
  test "the same call twice at once commits once, and the repeat is refused", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    expect(Tools, :stop_os_process, fn _scope, %OsProcess{} = stopping, _opts ->
      stopped = stopping |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
      {:ok, stopped}
    end)

    expect(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
      git!(path, ["push", "origin", "HEAD"])
      :ok
    end)

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    calls =
      for _n <- 1..2,
          do: Elixir.Task.async(fn -> Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add it"}) end)

    results = Elixir.Task.await_many(calls)

    assert [{:ok, :committing}, {:refused, "Refused, nothing committed again. This turn has already ended" <> _rest}] =
             Enum.sort_by(results, &(elem(&1, 0) != :ok))

    assert_receive {:run_changed, ^run_id}, 5_000

    assert repo |> git!(["log", "--pretty=%s"]) |> String.split("\n") |> Enum.count(&(&1 == "ETC-1: add it")) == 1
    assert %Run{status: :finished, stage_outcome: :done, error: nil} = Repo.get!(Run, run_id)
  end

  test "a blank or missing message is refused while the turn is still going", %{
    task: task,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. `message` is required" <> _rest} =
             Pipeline.end_turn_and_commit(task, os_process, %{"message" => "  "})

    assert {:refused, "Refused, nothing committed. `message` is required" <> _rest} =
             Pipeline.end_turn_and_commit(task, os_process, %{})
  end

  test "a worktree with nothing changed is refused", %{task: task, os_process: os_process} do
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. Nothing in the worktree has changed." <> _rest} =
             Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: nothing"})
  end

  test "a turn resolving a merge is refused, since that commit is Rail's", %{
    task: task,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, task} = Pipeline.update_task(task, %{is_updating_branch: true})
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. This turn is resolving a merge" <> _rest} =
             Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: resolve"})
  end

  # Past Engineer the branch is Review's, and its fixes are committed by the Review lead.
  test "a task past Engineer is refused, since the work is no longer this conversation's to commit", %{
    task: task,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    reject(Tools, :stop_os_process, 3)

    assert {:refused,
            "Refused, nothing committed. The task is at Review, so your work is no longer committed from this conversation."} =
             Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add it"})
  end

  test "after a CI failure, nothing changed runs CI again on the same commit", %{
    project: project,
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _streak} = Pipeline.update_run(run, %{ci_failure_streak: 1})

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)
    reject(&Git.push_branch/2)

    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
      {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, :committing} =
             Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: rerun CI past a flaky test"})

    assert_receive {:run_changed, ^run_id}, 5_000

    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "initial commit"
    assert %Run{status: :running, stage_outcome: :in_progress} = Repo.get!(Run, run_id)
  end

  test "on a project with CI, the commit starts CI on the new head and is not done until it passes", %{
    project: project,
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    head_before = String.trim(git!(repo, ["rev-parse", "HEAD"]))

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)
    reject(&Git.push_branch/2)

    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", opts ->
      refute opts[:head_sha] == head_before
      {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:run_changed, ^run_id}, 5_000

    # CI passing on it is what sends the task to Review, with nobody clicking.
    assert %Run{status: :running, stage_outcome: :in_progress, error: nil, review_on_ci_pass: true} =
             Repo.get!(Run, run_id)

    refute Git.worktree_dirty?(repo)
  end

  test "CI that cannot get a credential is recorded on the run", %{
    project: project,
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:error, {:github_api_error, 404, %{}}} end)
    reject(Tools, :start_command_process, 4)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not commit: Could not start CI: " <> _reason} = Repo.get!(Run, run_id)
  end

  # Another run's sandbox holds all 4 CPUs the test machine has (config/test.exs).
  test "CI waiting in line for room keeps the run open and a queued message for after it", %{
    project: project,
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, review_role} = Roles.get_role(project_id: project.id, stage: :review)

    {:ok, other} =
      Pipeline.create_run(%{task_id: task.id, role_id: review_role.id, status: :running, started_at: DateTime.utc_now()})

    Repo.insert!(%OsProcess{
      run_id: other.id,
      task_id: task.id,
      stream_path: "/dev/null",
      status: :running,
      started_at: DateTime.utc_now(),
      reserved_cpus: 4,
      reserved_memory_gb: 2
    })

    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Also tidy the tests"})
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)
    reject(Tools, :start_os_process, 2)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})

    # Joining the line says so on the run's topic too, so the settle is waited for.
    eventually(fn ->
      assert %Run{status: :waiting_for_resources, stage_outcome: :in_progress, pending_chat: "Also tidy the tests"} =
               Repo.get!(Run, run_id)
    end)
  end

  test "a push that fails is recorded on the run", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not commit: remote rejected", stage_outcome: :in_progress} =
             Repo.get!(Run, run_id)
  end

  # The agent is already stopped, so a crash must still reach the human, and the
  # message they queued must still go out.
  test "a commit that raises is recorded on the run and in the conversation", %{
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> raise "the remote hung up" end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not finish the turn: the remote hung up", stage_outcome: :in_progress} =
             Repo.get!(Run, run_id)

    assert "[rail] Could not finish the turn: the remote hung up" in Enum.map(
             Pipeline.list_run_events(run),
             & &1.line
           )
  end

  test "a commit that raises still sends a queued message, and the conversation keeps why", %{
    task: task,
    run: run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Also rename the filter"})
    test_pid = self()

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> raise "the remote hung up" end)

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:dispatched, argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:dispatched, argv}, 5_000
    assert Enum.any?(argv, &(&1 =~ "Also rename the filter"))

    assert "[rail] Could not finish the turn: the remote hung up" in Enum.map(
             Pipeline.list_run_events(run),
             & &1.line
           )
  end

  # Git's refusals run to several lines, and a log line is one: the rest would read
  # as the agent's own words.
  test "a failure over several lines is said on one", %{
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote: GH006: Protected branch\nTo origin.git\n"} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:run_changed, ^run_id}, 5_000

    assert ["[rail] Could not commit: remote: GH006: Protected branch To origin.git"] =
             Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "a failure git gives no words for is spelled out on the run", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :commit_worktree, fn _scope, _task, _message -> {:error, :index_locked} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not commit: :index_locked"} = Repo.get!(Run, run_id)
  end

  # The queue comes off the row before the stop, so the stopped turn's settle
  # cannot send it from under the commit, and it goes out once the run is idle.
  test "a message the human queued is held through the commit and sent after it", %{
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Also rename the filter"})
    test_pid = self()

    expect(Tools, :stop_os_process, fn _scope, _os_process, _opts ->
      assert %Run{pending_chat: nil} = Repo.get!(Run, run_id)
      {:ok, os_process}
    end)

    stub(Git, :push_branch, fn _scope, _task -> :ok end)

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:dispatched, argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, %{"message" => "ETC-1: add the feature"})
    assert_receive {:dispatched, argv}, 5_000
    assert Enum.any?(argv, &(&1 =~ "Also rename the filter"))
  end

  describe "the Review lead's commit" do
    setup %{project: project, task: task, run: engineer_run} do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)
      # The engineer handed its work on before the task reached Review.
      {:ok, _handed_on} = Pipeline.update_run(engineer_run, %{status: :finished, stage_outcome: :done})
      {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 7})

      {:ok, crash} =
        Pipeline.save_finding(task, %{
          key: "nil-crash",
          kind: :code,
          raised_by: :code_reviewer,
          title: "Nil crashes the page",
          problem: "It crashes.",
          file: "lib/a.ex",
          line: 3,
          fix: "Guard it.",
          why: "It crashes.",
          rule: "Every caller handles nil.",
          severity: :major,
          recommendation: :fix,
          places: [%{file: "lib/a.ex", line: 3}, %{file: "lib/b.ex", line: 9, label: "the other caller"}],
          evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
        })

      {:ok, %{round: 1}} = Pipeline.save_review(task)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)

      {:ok, lead_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :running,
          conversation_id: "sess_commit_fixes",
          started_at: DateTime.utc_now()
        })

      {:ok, lead_process} =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: lead_run.id,
          task_id: task.id,
          stream_path: "/tmp/commit_fixes/#{lead_run.id}.ndjson",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert()

      Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{lead_run.id}")

      %{
        task: task,
        lead_run: lead_run,
        lead_process: lead_process,
        round: %{
          "message" => "Guard the nil everywhere\n\nBoth callers check it now.",
          "findings" => [
            %{
              "key" => "nil-crash",
              "covered" => [1],
              "left" => [%{"place" => 2, "reason" => "The other caller never sees nil."}],
              "test" => %{"file" => "test/a_test.exs", "name" => "a missing worktree does not crash"}
            }
          ]
        }
      }
    end

    test "a round that leaves out a Fix finding, or lists one that is not, is refused", %{
      task: task,
      lead_process: lead_process,
      round: round
    } do
      reject(Tools, :stop_os_process, 3)

      assert {:refused, "Refused, nothing committed. the round leaves out nil-crash, ruled Fix." <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "findings" => []})

      made_up = %{"key" => "made-up", "covered" => [1], "test" => %{"file" => "t", "name" => "n"}}

      assert {:refused, "Refused, nothing committed. made-up is not a finding ruled Fix and still to fix."} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "findings" => [made_up | round["findings"]]})

      assert {:refused, "Refused, nothing committed. every entry in `findings` names its finding by `key`."} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "findings" => [%{"covered" => [1]}]})

      assert {:refused, "Refused, nothing committed. the round leaves out nil-crash, ruled Fix." <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, Map.delete(round, "findings"))
    end

    test "a Fix finding listed without a place, without a test, or with a place unaccounted for is refused", %{
      task: task,
      lead_process: lead_process,
      round: round
    } do
      reject(Tools, :stop_os_process, 3)
      [fix] = round["findings"]

      assert {:refused, "Refused, nothing committed. nil-crash is listed without a place" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "findings" => [%{fix | "covered" => []}]})

      assert {:refused, "Refused, nothing committed. nil-crash is listed without a test" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "findings" => [Map.delete(fix, "test")]})

      assert {:refused, "Refused, nothing committed. nil-crash leaves place 2 unaccounted for" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "findings" => [%{fix | "left" => []}]})

      blank = [%{"place" => 2, "reason" => " "}]

      assert {:refused, "Refused, nothing committed. nil-crash leaves a place with no reason." <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "findings" => [%{fix | "left" => blank}]})
    end

    test "a blank message, a bad list of other files, or nothing changed is refused", %{
      task: task,
      lead_process: lead_process,
      round: round
    } do
      reject(Tools, :stop_os_process, 3)

      assert {:refused, "Refused, nothing committed. `message` is required" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, %{round | "message" => "  "})

      assert {:refused, "Refused, nothing committed. `message` is required" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, Map.delete(round, "message"))

      assert {:refused,
              "Refused, nothing committed. each entry in `other_files` needs the `path` and the `reason`" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, Map.put(round, "other_files", [%{"path" => "x"}]))

      assert {:refused, "Refused, nothing committed. nothing in the worktree has changed." <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, round)
    end

    # A conflict-resolving turn stages its files, and Rail commits the merge once it stops.
    test "a turn resolving a merge is refused before the round is checked", %{
      task: task,
      lead_process: lead_process,
      round: round
    } do
      {:ok, task} = Pipeline.update_task(task, %{is_updating_branch: true})
      reject(Tools, :stop_os_process, 3)

      assert {:refused, "Refused, nothing committed. This turn is resolving a merge" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, round)
    end

    test "a changed file nothing listed explains is refused, and accepted with a reason the conversation shows", %{
      task: task,
      lead_run: %Run{id: run_id},
      repo: repo,
      lead_process: lead_process,
      round: round
    } do
      File.mkdir_p!(Path.join(repo, "lib"))
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")
      File.write!(Path.join(repo, "mix.lock"), "bumped\n")

      assert {:refused, "Refused, nothing committed. mix.lock changed, and no place, test or reason you listed" <> _rest} =
               Pipeline.end_turn_and_commit(task, lead_process, round)

      stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, lead_process} end)
      expect(Git, :push_branch, fn _scope, _task -> :ok end)
      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      other = [%{"path" => "mix.lock", "reason" => "The guard needs the newer library."}]

      assert {:ok, :committing} =
               Pipeline.end_turn_and_commit(task, lead_process, Map.put(round, "other_files", other))

      assert_receive {:run_changed, ^run_id}, 5_000

      assert ["[rail] mix.lock changed in fix round 1: The guard needs the newer library."] =
               %Run{id: run_id} |> Pipeline.list_run_events() |> Enum.map(& &1.line) |> Enum.filter(&(&1 =~ "mix.lock"))
    end

    test "an accepted round is one commit labeled Fix round 1, each finding fixed in it with its note, then the next round",
         %{
           task: task,
           lead_run: %Run{id: run_id},
           repo: repo,
           lead_process: %OsProcess{id: lead_process_id} = lead_process,
           round: round
         } do
      File.mkdir_p!(Path.join(repo, "lib"))
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")
      test_pid = self()

      expect(Tools, :stop_os_process, fn _scope, %OsProcess{id: ^lead_process_id}, opts ->
        assert opts[:ended_reason] == :handed_over
        {:ok, lead_process}
      end)

      expect(Git, :push_branch, fn _scope, _task -> :ok end)

      expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, _argv ->
        send(test_pid, :resumed)
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, lead_process, round)
      assert_receive {:run_changed, ^run_id}, 5_000

      head = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
      message = git!(repo, ["log", "-1", "--pretty=%B"])
      assert message =~ ~r/\AGuard the nil everywhere\n\nBoth callers check it now.\n\nTicket: ETC-1/
      assert message =~ "Rail-Step: Fix round 1"

      assert [
               %Finding{
                 status: :fixed,
                 fixed_in: ^head,
                 places: [%FindingPlace{left_reason: nil}, %FindingPlace{left_reason: "The other caller never sees nil."}],
                 notes: [
                   %FindingNote{kind: :raised},
                   %FindingNote{kind: :ruling},
                   %FindingNote{
                     kind: :fix,
                     round: 1,
                     commit: ^head,
                     covered: ["lib/a.ex:3"],
                     left: ["lib/b.ex:9: The other caller never sees nil."],
                     test: "test/a_test.exs: a missing worktree does not crash"
                   }
                 ]
               }
             ] = Pipeline.list_findings(task)

      assert_received :resumed
      assert %Task{stage: :review} = Repo.reload!(task)

      assert ["[rail] Round 2 started after it was pushed"] =
               %Run{id: run_id} |> Pipeline.list_run_events() |> Enum.map(& &1.line) |> Enum.filter(&(&1 =~ "Round 2"))
    end

    # The migration leaves a finding with no file or screen without places, and it is still fixed by one.
    test "a Fix finding with no places is committed, its note naming none", %{
      task: task,
      lead_run: %Run{id: run_id},
      repo: repo,
      lead_process: lead_process,
      round: round
    } do
      %Finding{id: placeless_id} =
        Repo.insert!(%Finding{
          task_id: task.id,
          key: "old-crash",
          kind: :code,
          raised_by: :code_reviewer,
          round: 1,
          title: "An old crash",
          problem: "It crashes.",
          fix: "Guard it.",
          why: "It crashes.",
          rule: "Every caller handles nil.",
          severity: :major,
          recommendation: :fix,
          decision: :fix,
          places: []
        })

      File.mkdir_p!(Path.join(repo, "lib"))
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")
      File.write!(Path.join([repo, "lib", "c.ex"]), "guarded\n")
      File.write!(Path.join([repo, "test", "c_test.exs"]), "test\n")
      stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, lead_process} end)
      expect(Git, :push_branch, fn _scope, _task -> :ok end)
      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      placeless = %{
        "key" => "old-crash",
        "covered" => [1],
        "test" => %{"file" => "test/c_test.exs", "name" => "an old crash does not crash"}
      }

      other = [%{"path" => "lib/c.ex", "reason" => "The old crash's guard."}]

      assert {:ok, :committing} =
               Pipeline.end_turn_and_commit(
                 task,
                 lead_process,
                 Map.merge(round, %{"findings" => [placeless | round["findings"]], "other_files" => other})
               )

      assert_receive {:run_changed, ^run_id}, 5_000

      assert %Finding{status: :fixed, notes: [%FindingNote{kind: :fix, covered: [], left: []}]} =
               Repo.get!(Finding, placeless_id)
    end

    test "on a project with CI the round runs CI on the lead's run, and after a failure nothing changed runs it again", %{
      project: project,
      task: task,
      lead_run: %Run{id: run_id} = lead_run,
      repo: repo,
      lead_process: lead_process,
      round: round
    } do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
      File.mkdir_p!(Path.join(repo, "lib"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      File.write!(Path.join(repo, "test_a.exs"), "test\n")
      round = put_in(round, ["findings", Access.at(0), "test", "file"], "test_a.exs")

      stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, lead_process} end)
      stub(Git, :credential_env, fn _project -> {:ok, %{}} end)
      reject(&Git.push_branch/2)

      expect(Tools, :start_command_process, fn %Run{id: ^run_id} = spawned, :ci, "mise run ci", _opts ->
        {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
        {:ok, %OsProcess{kind: :ci, run: spawned}}
      end)

      assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, lead_process, round)
      assert_receive {:run_changed, ^run_id}, 5_000
      assert %Run{status: :running, error: nil, review_on_ci_pass: true} = Repo.get!(Run, run_id)
      commits = git!(repo, ["rev-list", "--count", "HEAD"])

      {:ok, _failed} = Pipeline.update_run(lead_run, %{status: :running, ci_failure_streak: 1})

      {:ok, rerun} =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: run_id,
          task_id: task.id,
          stream_path: "/tmp/commit_fixes/#{run_id}.rerun.ndjson",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert()

      expect(Tools, :start_command_process, fn %Run{id: ^run_id} = spawned, :ci, "mise run ci", _opts ->
        {:ok, %OsProcess{kind: :ci, run: spawned}}
      end)

      assert {:ok, :committing} =
               Pipeline.end_turn_and_commit(task, rerun, %{"message" => "Run CI again", "findings" => []})

      assert_receive {:run_changed, ^run_id}, 5_000
      assert git!(repo, ["rev-list", "--count", "HEAD"]) == commits
    end

    test "the same call twice at once commits once, and the repeat is refused", %{
      task: task,
      lead_run: %Run{id: run_id},
      repo: repo,
      lead_process: lead_process,
      round: round
    } do
      File.mkdir_p!(Path.join(repo, "lib"))
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")

      expect(Tools, :stop_os_process, fn _scope, %OsProcess{} = stopping, _opts ->
        stopped = stopping |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
        {:ok, stopped}
      end)

      expect(Git, :push_branch, fn _scope, _task -> :ok end)
      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      calls = for _n <- 1..2, do: Elixir.Task.async(fn -> Pipeline.end_turn_and_commit(task, lead_process, round) end)

      assert [{:ok, :committing}, {:refused, "Refused, nothing committed again. This turn has already ended" <> _rest}] =
               calls |> Elixir.Task.await_many() |> Enum.sort_by(&(elem(&1, 0) != :ok))

      assert_receive {:run_changed, ^run_id}, 5_000

      assert repo |> git!(["log", "--pretty=%s"]) |> String.split("\n") |> Enum.count(&(&1 == "Guard the nil everywhere")) ==
               1
    end

    test "a push that fails is said on the run", %{
      task: task,
      lead_run: %Run{id: run_id},
      repo: repo,
      lead_process: lead_process,
      round: round
    } do
      File.mkdir_p!(Path.join(repo, "lib"))
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")
      stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, lead_process} end)
      expect(Git, :push_branch, fn _scope, _task -> {:error, "rejected"} end)

      assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, lead_process, round)
      assert_receive {:run_changed, ^run_id}, 5_000
      assert %Run{error: "Could not commit: rejected", review_on_ci_pass: false} = Repo.get!(Run, run_id)
    end

    test "a commit that fails is said on the run", %{
      task: task,
      lead_run: %Run{id: run_id},
      repo: repo,
      lead_process: lead_process,
      round: round
    } do
      File.mkdir_p!(Path.join(repo, "lib"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, lead_process} end)
      expect(Git, :commit_worktree, fn _scope, _task, _message -> {:error, :index_locked} end)
      reject(&Git.push_branch/2)

      assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, lead_process, round)
      assert_receive {:run_changed, ^run_id}, 5_000
      assert %Run{error: "Could not commit: :index_locked"} = Repo.get!(Run, run_id)
      assert [%Finding{status: :open}] = Pipeline.list_findings(task)
    end

    test "CI that will not start is said on the run", %{
      project: project,
      task: task,
      lead_run: %Run{id: run_id},
      repo: repo,
      lead_process: lead_process,
      round: round
    } do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
      File.mkdir_p!(Path.join(repo, "lib"))
      File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
      stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, lead_process} end)
      stub(Git, :credential_env, fn _project -> {:ok, %{}} end)
      expect(Tools, :start_command_process, fn _run, :ci, "mise run ci", _opts -> {:error, :no_sandbox} end)

      assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, lead_process, round)
      assert_receive {:run_changed, ^run_id}, 5_000

      assert %Run{error: "Could not commit: Could not start CI: :no_sandbox", review_on_ci_pass: false} =
               Repo.get!(Run, run_id)
    end
  end
end
