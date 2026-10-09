defmodule Rail.Pipeline.Actions.EndTurnAndCommitFixesTest do
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
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_ecf_1", "identifier" => "ECF-1", "title" => "Commit Fixes"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Commit Fixes"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    repo = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo, pr_number: 7})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

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

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_commit_fixes",
        started_at: DateTime.utc_now()
      })

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/commit_fixes/#{run.id}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    %{
      task: task,
      run: run,
      repo: repo,
      os_process: os_process,
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
    os_process: os_process,
    round: round
  } do
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. the round leaves out nil-crash, ruled Fix." <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "findings" => []})

    made_up = %{"key" => "made-up", "covered" => [1], "test" => %{"file" => "t", "name" => "n"}}

    assert {:refused, "Refused, nothing committed. made-up is not a finding ruled Fix and still to fix."} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "findings" => [made_up | round["findings"]]})

    assert {:refused, "Refused, nothing committed. every entry in `findings` names its finding by `key`."} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "findings" => [%{"covered" => [1]}]})
  end

  test "a Fix finding listed without a place, without a test, or with a place unaccounted for is refused", %{
    task: task,
    os_process: os_process,
    round: round
  } do
    reject(Tools, :stop_os_process, 3)
    [fix] = round["findings"]

    assert {:refused, "Refused, nothing committed. nil-crash is listed without a place" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "findings" => [%{fix | "covered" => []}]})

    assert {:refused, "Refused, nothing committed. nil-crash is listed without a test" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "findings" => [Map.delete(fix, "test")]})

    assert {:refused, "Refused, nothing committed. nil-crash leaves place 2 unaccounted for" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "findings" => [%{fix | "left" => []}]})

    blank = [%{"place" => 2, "reason" => " "}]

    assert {:refused, "Refused, nothing committed. nil-crash leaves a place with no reason." <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "findings" => [%{fix | "left" => blank}]})
  end

  test "a blank message, a bad list of other files, or nothing changed is refused", %{
    task: task,
    os_process: os_process,
    round: round
  } do
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. `message` is required" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, %{round | "message" => "  "})

    assert {:refused, "Refused, nothing committed. `message` is required" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, Map.delete(round, "message"))

    assert {:refused, "Refused, nothing committed. commit_fixes needs a `message`" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, nil)

    assert {:refused,
            "Refused, nothing committed. each entry in `other_files` needs the `path` and the `reason`" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, Map.put(round, "other_files", [%{"path" => "x"}]))

    assert {:refused, "Refused, nothing committed. nothing in the worktree has changed." <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, round)
  end

  test "a changed file nothing listed explains is refused, and accepted with a reason the conversation shows", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process,
    round: round
  } do
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
    File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")
    File.write!(Path.join(repo, "mix.lock"), "bumped\n")

    assert {:refused, "Refused, nothing committed. mix.lock changed, and no place, test or reason you listed" <> _rest} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, round)

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    expect(Git, :push_branch, fn _scope, _task -> :ok end)
    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    other = [%{"path" => "mix.lock", "reason" => "The guard needs the newer library."}]

    assert {:ok, :committing} =
             Pipeline.end_turn_and_commit_fixes(task, os_process, Map.put(round, "other_files", other))

    assert_receive {:run_changed, ^run_id}, 5_000

    assert ["[rail] mix.lock changed in fix round 1: The guard needs the newer library." | _rest] =
             run_id
             |> then(&Pipeline.list_run_events(%Run{id: &1}))
             |> Enum.map(& &1.line)
             |> Enum.filter(&(&1 =~ "mix.lock"))
  end

  test "an accepted round is one commit labeled Fix round 1, each finding fixed in it with its note, then the next round",
       %{
         task: task,
         run: %Run{id: run_id},
         repo: repo,
         os_process: %OsProcess{id: os_process_id} = os_process,
         round: round
       } do
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
    File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")
    test_pid = self()

    expect(Tools, :stop_os_process, fn _scope, %OsProcess{id: ^os_process_id}, opts ->
      assert opts[:ended_reason] == :handed_over
      {:ok, os_process}
    end)

    expect(Git, :push_branch, fn _scope, _task -> :ok end)

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      send(test_pid, {:resumed, prompt})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit_fixes(task, os_process, round)
    assert_receive {:run_changed, ^run_id}, 5_000

    head = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
    message = git!(repo, ["log", "-1", "--pretty=%B"])
    assert message =~ ~r/\AGuard the nil everywhere\n\nBoth callers check it now.\n\nTicket: ECF-1/
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

    assert_received {:resumed, prompt}
    assert prompt =~ "Run round 2"
    assert %Task{stage: :review} = Repo.reload!(task)

    assert ["[rail] Round 2 started after it was pushed"] =
             %Run{id: run_id} |> Pipeline.list_run_events() |> Enum.map(& &1.line) |> Enum.filter(&(&1 =~ "Round 2"))
  end

  test "on a project with CI the round runs CI on the Review run, and after a failure nothing changed runs it again", %{
    project: project,
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process,
    round: round
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
    File.write!(Path.join(repo, "test_a.exs"), "test\n")
    round = put_in(round, ["findings", Access.at(0), "test", "file"], "test_a.exs")

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)
    reject(&Git.push_branch/2)

    expect(Tools, :start_command_process, fn %Run{id: ^run_id} = spawned, :ci, "mise run ci", _opts ->
      {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit_fixes(task, os_process, round)
    assert_receive {:run_changed, ^run_id}, 5_000
    assert %Run{status: :running, error: nil} = Repo.get!(Run, run_id)
    commits = git!(repo, ["rev-list", "--count", "HEAD"])

    {:ok, _failed} = Pipeline.update_run(run, %{status: :running, ci_failure_streak: 1})

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
             Pipeline.end_turn_and_commit_fixes(task, rerun, %{"message" => "Run CI again", "findings" => []})

    assert_receive {:run_changed, ^run_id}, 5_000
    assert git!(repo, ["rev-list", "--count", "HEAD"]) == commits
  end

  test "the same call twice at once commits once, and the repeat is refused", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process,
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

    calls = for _n <- 1..2, do: Elixir.Task.async(fn -> Pipeline.end_turn_and_commit_fixes(task, os_process, round) end)

    assert [{:ok, :committing}, {:refused, "Refused, nothing committed again. This turn has already ended" <> _rest}] =
             calls |> Elixir.Task.await_many() |> Enum.sort_by(&(elem(&1, 0) != :ok))

    assert_receive {:run_changed, ^run_id}, 5_000

    assert repo |> git!(["log", "--pretty=%s"]) |> String.split("\n") |> Enum.count(&(&1 == "Guard the nil everywhere")) ==
             1
  end

  test "a push that fails is said on the run", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process,
    round: round
  } do
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
    File.write!(Path.join([repo, "test", "a_test.exs"]), "test\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    expect(Git, :push_branch, fn _scope, _task -> {:error, "rejected"} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit_fixes(task, os_process, round)
    assert_receive {:run_changed, ^run_id}, 5_000
    assert %Run{error: "rejected"} = Repo.get!(Run, run_id)
  end

  test "a commit that fails is said on the run", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process,
    round: round
  } do
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    expect(Git, :commit_worktree, fn _scope, _task, _message -> {:error, :index_locked} end)
    reject(&Git.push_branch/2)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit_fixes(task, os_process, round)
    assert_receive {:run_changed, ^run_id}, 5_000
    assert %Run{error: "Could not commit fix round 1: :index_locked"} = Repo.get!(Run, run_id)
  end

  test "CI that will not start is said on the run", %{
    project: project,
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process,
    round: round
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join([repo, "lib", "a.ex"]), "guarded\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)
    expect(Tools, :start_command_process, fn _run, :ci, "mise run ci", _opts -> {:error, :no_sandbox} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit_fixes(task, os_process, round)
    assert_receive {:run_changed, ^run_id}, 5_000
    assert %Run{error: "Could not start CI: :no_sandbox"} = Repo.get!(Run, run_id)
  end
end
