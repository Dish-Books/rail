defmodule Rail.Pipeline.Actions.HandOverWorkTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_hand_over_work_1",
              "identifier" => "CMW-1",
              "title" => "Invoice filters",
              "url" => "https://linear.app/rail/issue/CMW-1"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Invoice filters"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    # Review only takes a branch the remote has, so pushing here has to reach one.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "--set-upstream", "origin", "main"])
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "CMW-1: add the vendor filter"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
      git!(path, ["push", "origin", "HEAD"])
      :ok
    end)

    # The check fetches with a token of its own, which the pull request tests would count.
    stub(Git, :check_push, fn _task -> :ok end)

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

    # Going on to Review starts the Review lead.
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_hand_over_work",
        started_at: DateTime.utc_now()
      })

    %{issue: issue, scope: scope, project: project, run: run, task: task, repo: repo}
  end

  describe "at Engineer" do
    test "with no CI, the pushed commit goes on to review", %{scope: scope, run: run, task: task, repo: repo} do
      {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})

      assert {:ok, %Run{stage_outcome: :done}} = Pipeline.hand_over_work(scope, run)
      refute Git.branch_unpushed?(repo)
      assert %Task{stage: :review} = Repo.reload!(task)
      assert %Run{stage_outcome: :done, review_on_ci_pass: false, error: nil} = Repo.reload!(run)
    end

    # Work left uncommitted is not handed over: the agent commits what is finished.
    test "a branch with nothing unpushed is refused with nothing sent", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      git!(repo, ["push", "origin", "HEAD"])
      File.write!(Path.join(repo, "later.ex"), "uncommitted\n")
      reject(&Git.push_branch/2)

      assert {:error, :nothing_to_send} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    # Rail never force-pushes, so a branch that rewrote what it pushed is refused before CI or a push.
    test "a branch that rewrote commits already pushed is refused, with nothing pushed", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      {:ok, task} = Pipeline.update_task(task, %{worktree_name: "main"})
      stub(Git, :check_push, &call_original(Git, :check_push, [&1]))
      git!(repo, ["push", "origin", "HEAD"])
      git!(repo, ["commit", "--amend", "--allow-empty", "-m", "CMW-1: add the vendor filter, reworded"])
      reject(&Git.push_branch/2)

      assert {:error, :history_rewritten} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    # A push that failed left a commit never sent, which is what the button offers again.
    test "a push that failed sends nothing on and drops the go-ahead, and running again pushes", %{
      scope: scope,
      run: run,
      task: task
    } do
      stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

      assert {:error, "remote rejected"} = Pipeline.hand_over_work(scope, run)
      assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        git!(path, ["push", "origin", "HEAD"])
        :ok
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "a push review would still refuse leaves the task in engineer, pushed", %{
      scope: scope,
      project: project,
      run: run,
      task: task,
      repo: repo
    } do
      {:ok, review_role} = Roles.get_role(project_id: project.id, stage: :review)

      {:ok, _working} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: review_role.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})

      assert {:error, :stage_running} = Pipeline.hand_over_work(scope, run)
      refute Git.branch_unpushed?(repo)
      assert %Run{error: nil} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    # Once Engineer hands the branch on it is Review's, and the Review lead hands its fixes on.
    test "the engineer's hand-over on a task at Review is refused, with nothing pushed and no go-ahead left", %{
      scope: scope,
      run: run,
      task: task
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
      reject(&Git.push_branch/2)

      assert {:error, {:invalid_stage, :review}} = Pipeline.hand_over_work(scope, run)
      assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    # The diff pane can hold a run whose task it loaded before someone else sent it on.
    test "a push from a page that still thinks the task is at engineer is refused", %{
      scope: scope,
      run: run,
      task: task
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
      reject(&Git.push_branch/2)

      assert {:error, {:invalid_stage, :review}} = Pipeline.hand_over_work(scope, %{run | task: task})
    end

    test "with CI, the commit waits on CI, holding the go-ahead for when it passes", %{
      scope: scope,
      project: project,
      run: run,
      task: task
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})

      reject(&Git.push_branch/2)
      stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

      expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
        {:ok, %OsProcess{kind: :ci, run: spawned}}
      end)

      assert {:ok, %Run{status: :running, review_on_ci_pass: true}} =
               Pipeline.hand_over_work(scope, run)

      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "with CI that cannot start, says why and drops the go-ahead", %{
      scope: scope,
      project: project,
      run: run,
      task: task
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
      stub(Git, :credential_env, fn _project -> {:error, {:github_api_error, 401, %{}}} end)
      reject(&Git.push_branch/2)

      assert {:error, "Could not start CI: {:github_api_error, 401, %{}}"} = Pipeline.hand_over_work(scope, run)
      assert %Run{status: :finished, review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a commit CI already passed is pushed without running CI again, and goes on to review", %{
      scope: scope,
      project: project,
      run: run,
      task: task,
      repo: repo
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})

      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        exit_code: 0,
        head_sha: String.trim(git!(repo, ["rev-parse", "HEAD"])),
        stream_path: "/tmp/cmw-ci.log",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      reject(Tools, :start_command_process, 4)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      refute Git.branch_unpushed?(repo)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "the first push opens the task's pull request as a draft, and keeps it", %{scope: scope, run: run, task: task} do
      Req.Test.expect(Client, 3, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-seed/pulls"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/example/test-seed/pulls"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            assert %{
                     "title" => "CMW-1 Invoice filters",
                     "head" => "cmw-1",
                     "base" => "main",
                     "draft" => true,
                     "body" => "https://linear.app/rail/issue/CMW-1\n\nOpened by Rail as a draft." <> _rest
                   } = Jason.decode!(body)

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "number" => 12,
              "html_url" => "https://github.com/example/test-seed/pull/12",
              "draft" => true
            })
        end
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)

      assert %Task{pr_number: 12, pr_url: "https://github.com/example/test-seed/pull/12", pr_is_draft: true} =
               Repo.reload!(task)
    end

    test "an open pull request already on the branch is adopted, not opened twice", %{scope: scope, run: run, task: task} do
      Req.Test.expect(Client, 2, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/" <> _id} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-seed/pulls"} ->
            Req.Test.json(conn, [
              %{"number" => 9, "html_url" => "https://github.com/example/test-seed/pull/9", "draft" => false}
            ])
        end
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: 9, pr_is_draft: false} = Repo.reload!(task)
    end

    test "a task that has its pull request does not ask GitHub again", %{scope: scope, run: run, task: task} do
      {:ok, _opened} = Pipeline.update_task(task, %{pr_number: 5, pr_url: "https://github.com/example/test-seed/pull/5"})
      Req.Test.stub(Client, fn _conn -> flunk("asked GitHub about a pull request the task already has") end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
    end

    test "a pull request that cannot be opened is said in the run's log, and the push still stands", %{
      scope: scope,
      task: task,
      run: %Run{id: run_id} = run
    } do
      Req.Test.expect(Client, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: nil, stage: :review} = Repo.reload!(task)

      assert [%RunEvent{line: "[rail] Could not open the pull request: " <> _reason}] =
               RunEvent |> where(run_id: ^run_id) |> Repo.all()
    end

    test "the pull request is opened as the ticket's owner", %{scope: scope, run: run, task: task, issue: issue} do
      {:ok, owner} =
        %User{}
        |> User.changeset(%{
          github_id: "gh_cmw",
          login: "ada",
          name: "Ada",
          email: "ada@example.com",
          github_token: "gho_ada"
        })
        |> Repo.insert()

      {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: owner.id})

      Req.Test.expect(Client, 3, fn conn ->
        case {conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
          {"POST", "/app/installations/" <> _id, _auth} ->
            Req.Test.json(conn, %{"token" => "ghs_app"})

          {"GET", "/repos/example/test-seed/pulls", ["Bearer ghs_app"]} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/example/test-seed/pulls", ["Bearer gho_ada"]} ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 21, "html_url" => "https://github.com/example/test-seed/pull/21"})
        end
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: 21} = Repo.reload!(task)
    end

    test "an owner GitHub turns away has the pull request opened as the Rail app", %{
      scope: scope,
      run: run,
      task: task,
      issue: issue
    } do
      {:ok, owner} =
        %User{}
        |> User.changeset(%{
          github_id: "gh_cmw2",
          login: "bo",
          name: "Bo",
          email: "bo@example.com",
          github_token: "gho_bo"
        })
        |> Repo.insert()

      {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: owner.id})

      Req.Test.expect(Client, 4, fn conn ->
        case {conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
          {"POST", "/app/installations/" <> _id, _auth} ->
            Req.Test.json(conn, %{"token" => "ghs_app"})

          {"GET", "/repos/example/test-seed/pulls", _auth} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/example/test-seed/pulls", ["Bearer gho_bo"]} ->
            conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible"})

          {"POST", "/repos/example/test-seed/pulls", ["Bearer ghs_app"]} ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 22, "html_url" => "https://github.com/example/test-seed/pull/22"})
        end
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: 22} = Repo.reload!(task)
    end
  end

  describe "at Review" do
    setup %{project: project, task: task} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 7})
      {:ok, %{round: 1}} = Pipeline.save_review(task)
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

      {:ok, lead_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_hand_over_work_lead",
          started_at: DateTime.utc_now()
        })

      %{task: task, lead_run: lead_run}
    end

    test "the lead's commit is pushed and starts the next round", %{
      scope: scope,
      task: task,
      lead_run: %Run{id: lead_run_id} = lead_run,
      repo: repo
    } do
      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      test_pid = self()

      # Resumed as running, so the page shows the re-review and nothing can start another turn under it.
      expect(Tools, :start_os_process, fn %Run{id: ^lead_run_id, status: :running} = spawned, _argv ->
        send(test_pid, :resumed)
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{id: ^lead_run_id, stage_outcome: :in_progress, status: :running}} =
               Pipeline.hand_over_work(scope, lead_run)

      refute Git.branch_unpushed?(repo)
      assert_received :resumed
      assert %Task{stage: :review} = Repo.reload!(task)

      assert ["[rail] Round 2 started after it was pushed"] =
               lead_run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    # The lead saves a fix before or after the engineer commits it; either way it is in the commit handed over.
    test "a finding the lead saved fixed is noted as fixed in the commit handed over", %{
      scope: scope,
      task: %Task{id: task_id} = task,
      lead_run: lead_run,
      repo: repo
    } do
      {:ok, raised} =
        Pipeline.save_finding(task, %{
          key: "unhandled-nil",
          kind: :code,
          raised_by: :code_reviewer,
          title: "Nil is not handled",
          problem: "It crashes.",
          file: "feature.ex",
          line: 1,
          fix: "Guard it.",
          why: "It crashes.",
          rule: "Every caller handles nil.",
          severity: :major,
          recommendation: :fix,
          places: [%{file: "feature.ex", line: 1}],
          evidence: [%{name: "range", kind: :code, file: "feature.ex", line: 1}]
        })

      {:ok, _ruled} = Pipeline.decide_finding(scope, raised, :fix)

      {:ok, _fixed} =
        Pipeline.save_finding(task, %{
          "key" => "unhandled-nil",
          "status" => "fixed",
          "covered" => [1],
          "test" => %{"file" => "feature_test.exs", "name" => "handles nil"},
          "files" => ["feature.ex"]
        })

      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      head = String.trim(git!(repo, ["rev-parse", "HEAD"]))
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, lead_run)

      assert [%Finding{status: :fixed, fixed_in: ^head, notes: notes}] = Pipeline.list_findings(task)
      assert %FindingNote{kind: :fix, commit: ^head, test: "feature_test.exs: handles nil"} = List.last(notes)
      assert_received {:output_saved, ^task_id}
    end

    # A round is a read of a new HEAD, so a branch the last round already read is only pushed.
    test "a branch the last round already read is pushed and starts no round", %{
      scope: scope,
      task: task,
      lead_run: lead_run,
      repo: repo
    } do
      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      reject(Tools, :start_os_process, 2)

      assert {:ok, %Run{status: :finished, review_on_ci_pass: false}} = Pipeline.hand_over_work(scope, lead_run)
      refute Git.branch_unpushed?(repo)
      assert [] = Pipeline.list_run_events(lead_run)
    end

    test "with CI, the lead's commit runs CI on its run, and CI passing starts the next round", %{
      scope: scope,
      project: project,
      task: task,
      lead_run: %Run{id: lead_run_id} = lead_run,
      repo: repo
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

      expect(Tools, :start_command_process, fn %Run{id: ^lead_run_id} = spawned, :ci, "mise run ci", _opts ->
        {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
        {:ok, %OsProcess{kind: :ci, run: spawned}}
      end)

      assert {:ok, %Run{status: :running, review_on_ci_pass: true}} = Pipeline.hand_over_work(scope, lead_run)

      # CI holds the push, and the round, until it passes.
      assert Git.branch_unpushed?(repo)
      assert [] = Pipeline.list_run_events(lead_run)
      head = String.trim(git!(repo, ["rev-parse", "HEAD"]))

      ci =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: lead_run_id,
          task_id: task.id,
          kind: :ci,
          head_sha: head,
          stream_path: "/tmp/cmw-lead-ci.log",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      expect(Tools, :start_os_process, fn %Run{id: ^lead_run_id, status: :running} = spawned, _argv ->
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{review_on_ci_pass: false, error: nil, status: :running}} =
               Pipeline.run_finished(ci, %{exit_code: 0})

      refute Git.branch_unpushed?(repo)
      assert %Task{stage: :review} = Repo.reload!(task)

      assert ["[rail] Round 2 started after CI passed on " <> short] =
               lead_run |> Pipeline.list_run_events() |> Enum.map(& &1.line)

      assert String.starts_with?(head, short)
    end

    # The turn that handed its commits to CI ended running, so it was never latched; CI's pass ends its round.
    test "CI passing on a branch the last round read ends the round, which waits on the findings to rule", %{
      task: task,
      lead_run: %Run{id: lead_run_id} = lead_run,
      repo: repo
    } do
      {:ok, _finding} =
        Pipeline.save_finding(task, %{
          key: "unhandled-nil",
          kind: :code,
          raised_by: :code_reviewer,
          title: "Nil is not handled",
          problem: "It crashes.",
          file: "feature.ex",
          line: 1,
          fix: "Guard it.",
          why: "It crashes.",
          rule: "Every caller handles nil.",
          severity: :major,
          recommendation: :fix,
          places: [%{file: "feature.ex", line: 1}],
          evidence: [%{name: "range", kind: :code, file: "feature.ex", line: 1}]
        })

      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      {:ok, _open} = Pipeline.update_run(lead_run, %{stage_outcome: :in_progress, status: :running})
      reject(Tools, :start_os_process, 2)

      ci =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: lead_run_id,
          task_id: task.id,
          kind: :ci,
          stream_path: "/tmp/cmw-lead-ci.log",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:ok, %Run{stage_outcome: :done, status: :finished, error: nil}} =
               Pipeline.run_finished(ci, %{exit_code: 0})

      refute Git.branch_unpushed?(repo)
      assert :done = lead_run |> Repo.reload!() |> Repo.preload(:questions) |> Run.state()
      assert [%{finished_at: nil}, %{finished_at: nil}] = task |> Repo.preload(:issue) |> Pipeline.read_review()
      assert [] = Pipeline.list_run_events(lead_run)
    end

    test "CI passing on a branch the last round read, with nothing left to rule or fix, finishes the review", %{
      task: task,
      lead_run: %Run{id: lead_run_id} = lead_run,
      repo: repo
    } do
      {:ok, task} = Pipeline.update_task(task, %{pr_is_draft: true})
      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      {:ok, _open} = Pipeline.update_run(lead_run, %{stage_outcome: :in_progress, status: :running})

      Req.Test.stub(Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/" <> _id} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/" <> _pull} ->
            Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_7"})

          {"POST", "/graphql"} ->
            Req.Test.json(conn, %{
              "data" => %{"markPullRequestReadyForReview" => %{"pullRequest" => %{"isDraft" => false}}}
            })
        end
      end)

      ci =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: lead_run_id,
          task_id: task.id,
          kind: :ci,
          stream_path: "/tmp/cmw-lead-ci.log",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:ok, %Run{stage_outcome: :done, error: nil}} = Pipeline.run_finished(ci, %{exit_code: 0})
      assert %Task{stage: :review, pr_is_draft: false} = Repo.reload!(task)
      assert [_first, %{finished_at: %DateTime{}}] = task |> Repo.preload(:issue) |> Pipeline.read_review()
    end

    test "CI passing while the lead's question is unanswered leaves the round open on the answer", %{
      task: task,
      lead_run: %Run{id: lead_run_id} = lead_run,
      repo: repo
    } do
      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      {:ok, lead_run} = Pipeline.update_run(lead_run, %{stage_outcome: :in_progress})

      {:ok, _question} =
        Pipeline.register_question(Repo.preload(lead_run, task: :issue), %DetectedQuestion{prompt: "Keep the guard?"})

      ci =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: lead_run_id,
          task_id: task.id,
          kind: :ci,
          stream_path: "/tmp/cmw-lead-ci.log",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:ok, %Run{stage_outcome: :in_progress, error: nil}} = Pipeline.run_finished(ci, %{exit_code: 0})
      refute Git.branch_unpushed?(repo)
      assert :blocked = lead_run |> Repo.reload!() |> Repo.preload(:questions) |> Run.state()
    end

    test "with dispatch off, the lead's commit is pushed and says the round was not started", %{
      scope: scope,
      lead_run: lead_run,
      repo: repo
    } do
      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

      assert {:error, "Dispatch is off, so round 2 was not started."} = Pipeline.hand_over_work(scope, lead_run)
      refute Git.branch_unpushed?(repo)
      assert %Run{status: :finished} = Repo.reload!(lead_run)
    end

    test "the lead's hand-over on a task back at Engineer is refused, with nothing pushed", %{
      scope: scope,
      task: task,
      lead_run: lead_run,
      repo: repo
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})
      git!(repo, ["commit", "--allow-empty", "-m", "Guard the nil"])
      reject(&Git.push_branch/2)

      assert {:error, {:invalid_stage, :engineer}} = Pipeline.hand_over_work(scope, lead_run)
    end
  end
end
