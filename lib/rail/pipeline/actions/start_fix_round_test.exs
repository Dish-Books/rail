defmodule Rail.Pipeline.Actions.StartFixRoundTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sfr_1", "identifier" => "SFR-1", "title" => "Start Fix Round"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Start Fix Round"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo(), pr_number: 9, pr_is_draft: true})
    task = Repo.preload(task, :issue)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_sfr",
        started_at: DateTime.utc_now()
      })

    attrs = %{
      kind: :code,
      raised_by: :code_reviewer,
      problem: "It crashes.",
      file: "lib/a.ex",
      line: 3,
      fix: "Guard it.",
      why: "It crashes.",
      rule: "Every caller handles nil.",
      severity: :major,
      recommendation: :fix,
      places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}, %{file: "lib/b.ex", line: 9}],
      evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
    }

    {:ok, crash} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "nil-crash", title: "Nil crashes the page"}))
    {:ok, nit} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "a-nit", title: "A nit", severity: :nit}))
    {:ok, %{round: 1}} = Pipeline.save_review(task)

    %{task: task, run: run, crash: crash, nit: nit}
  end

  test "with findings ruled Fix it resumes the Review run on them, their rules and places, and the task stays at Review",
       %{task: task, run: %{id: run_id} = run, crash: crash, nit: nit} do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

    # Spawned as running, so a second click finds the stage busy and the page shows the fix round.
    expect(Tools, :start_os_process, fn %Run{id: ^run_id, stage_outcome: :in_progress, status: :running} = spawned,
                                        ["-p", prompt | _rest] ->
      assert prompt =~ "Start fix round 1. The human ruled these 1 findings Fix"
      assert prompt =~ ~s(<finding key="nil-crash" severity="major" kind="code">)
      assert prompt =~ "Rule: Every caller handles nil."
      assert prompt =~ "1. lib/a.ex:3, handle/1\n2. lib/b.ex:9"
      refute prompt =~ "a-nit"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{id: ^run_id, status: :running}} = Pipeline.start_fix_round(system_scope(), run)
    assert %Run{status: :running} = Repo.get!(Run, run_id)
    assert {:error, :stage_running} = Pipeline.start_fix_round(system_scope(), run)
    assert %Task{stage: :review} = Repo.reload!(task)
    assert [_line | _rest] = run |> Pipeline.list_run_events() |> Enum.filter(&(&1.line =~ "[human] Start fix round 1"))
    assert Repo.exists?(from o in Observation, where: o.source_id == ^crash.id and o.source_kind == :review_finding)
  end

  test "a Fix finding carried into the round goes again, marked still failing", %{
    task: task,
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 1"])

    {:ok, _fixed} =
      Pipeline.save_finding(task, %{
        key: "nil-crash",
        status: "fixed",
        covered: [1],
        left: [%{place: 2, reason: "Generated from the first."}],
        test: %{file: "test/crash_test.exs", name: "handles nil"}
      })

    {:ok, %{round: 2}} = Pipeline.save_review(task)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Merge main"])
    {:ok, %Finding{carried_round: 3}} = Pipeline.save_finding(task, %{key: "nil-crash", status: "not_fixed"})
    {:ok, %{round: 3}} = Pipeline.save_review(task)

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Start fix round 3."
      assert prompt =~ ~s(<finding key="nil-crash" severity="major" kind="code" still_failing="true">)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.start_fix_round(system_scope(), run)
  end

  test "with nothing ruled Fix the review finishes, the pull request leaves draft and the task moves to Finalize, once",
       %{
         task: task,
         run: run,
         crash: crash,
         nit: nit
       } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", "/repos/example/test-seed/pulls/9"} -> Req.Test.json(conn, %{"number" => 9, "node_id" => "PR_9"})
        {"POST", "/graphql"} -> Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    assert {:ok, %Run{status: :finished, task_id: task_id}} = Pipeline.start_fix_round(system_scope(), run)
    assert %Task{stage: :finalize, pr_is_draft: false} = Repo.reload!(task)
    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
    assert_received {:pipeline_changed, ^task_id}
    assert {:error, :nothing_to_start} = Pipeline.start_fix_round(system_scope(), run)
  end

  test "nothing ruled Fix leaves the review open while a finding waits on a ruling", %{
    task: task,
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
    # Recommended Don't fix and never ruled: it is no fix, but nobody has said so.
    nit |> Ecto.Changeset.change(recommendation: :skip) |> Repo.update!()

    assert {:error, {:undecided_findings, 1}} = Pipeline.start_fix_round(system_scope(), run)
    assert %Task{stage: :review} = Repo.reload!(task)
    assert [%{finished_at: nil}] = Pipeline.read_review(task)
  end

  # A chat turn that stopped or failed leaves the lead in progress with its error, which a finished review clears.
  test "Finish review after a stopped or failed chat turn saves the run done, with no error", %{
    task: task,
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
    {:ok, _no_pr} = Pipeline.update_task(task, %{pr_number: nil})
    {:ok, stopped} = Pipeline.update_run(run, %{stage_outcome: :in_progress, error: "The turn failed."})

    assert {:ok, %Run{stage_outcome: :done, error: nil, completed_at: %DateTime{}}} =
             Pipeline.start_fix_round(system_scope(), stopped)

    assert %Run{status: :finished, stage_outcome: :done, error: nil} = Repo.reload!(run)
  end

  # A fix's commit not yet through CI is still waiting on it, however the findings were ruled.
  test "on a project with CI, nothing ruled Fix finishes only once CI passed on HEAD", %{
    project: project,
    task: task,
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
    head = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()

    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: task.id,
      kind: :ci,
      command: "mise run ci",
      stream_path: "/dev/null",
      status: :finished,
      exit_code: 1,
      head_sha: head,
      started_at: DateTime.utc_now()
    })

    assert {:error, :ci_not_passed} = Pipeline.start_fix_round(system_scope(), run)
    assert %Task{pr_is_draft: true} = Repo.reload!(task)
    assert [%{finished_at: nil}] = Pipeline.read_review(task)

    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: task.id,
      kind: :ci,
      command: "mise run ci",
      stream_path: "/dev/null",
      status: :finished,
      exit_code: 0,
      head_sha: head,
      started_at: DateTime.utc_now()
    })

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", "/repos/example/test-seed/pulls/9"} -> Req.Test.json(conn, %{"number" => 9, "node_id" => "PR_9"})
        {"POST", "/graphql"} -> Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Run{status: :finished}} = Pipeline.start_fix_round(system_scope(), run)
    assert %Task{pr_is_draft: false} = Repo.reload!(task)
    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
  end

  test "a second start while the round it started works is refused", %{task: task, run: run, crash: crash, nit: nit} do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :fix)
    {:ok, _working} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.start_fix_round(system_scope(), run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "nothing starts before a round has finished, on a task back before Review, or on one cleaned up", %{
    task: task,
    run: run
  } do
    File.rm!(Path.join([task.scratch_path, "reviews", "SFR-1.json"]))
    assert {:error, :nothing_to_start} = Pipeline.start_fix_round(system_scope(), run)

    {:ok, merged} = Pipeline.update_task(task, %{stage: :merged})
    assert {:error, :nothing_to_start} = Pipeline.start_fix_round(system_scope(), run)

    {:ok, engineering} = Pipeline.update_task(merged, %{stage: :engineer})
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.start_fix_round(system_scope(), run)

    {:ok, _cleaned} = Pipeline.update_task(engineering, %{stage: :finalize, cleaned_up_at: DateTime.utc_now()})
    assert {:error, :cleaned_up} = Pipeline.start_fix_round(system_scope(), run)
  end

  test "a lead that cannot be spawned keeps its failure on the run, and dispatch off says so", %{
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :fix)

    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      {:error, {:spawn_failed, :enoent, %{spawned | error: "Could not start"}}}
    end)

    assert {:ok, %Run{error: "Could not start"}} = Pipeline.start_fix_round(system_scope(), run)
    # A failed spawn settles its run through run_finished, which this stub stands in for.
    {:ok, _settled} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished})

    expect(Tools, :start_os_process, fn %Run{}, _argv -> {:error, :dispatch_disabled} end)
    assert {:error, :dispatch_disabled} = Pipeline.start_fix_round(system_scope(), run)
    assert %Run{status: :finished} = Repo.reload!(run)
  end

  describe "the reader's comments" do
    setup %{task: task} do
      {:ok, ada} =
        Users.register_oauth_user(%{
          github_id: "gh_sfr_ada",
          login: "ada-start-fix-round",
          email: "ada-start-fix-round@example.com"
        })

      {:ok, grace} =
        Users.register_oauth_user(%{
          github_id: "gh_sfr_grace",
          login: "grace-start-fix-round",
          email: "grace-start-fix-round@example.com"
        })

      folder = Path.join([task.scratch_path, "qa", "screens", "file-list"])
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "1.jpg"), "jpeg")
      {:ok, _shot} = Pipeline.save_screen(task, %{key: "file-list", label: "File list", file: "screens/file-list/1.jpg"})

      %{
        ada: user_scope(user: ada),
        grace: user_scope(user: grace),
        diff: %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "x = 1", filter: :branch},
        head: task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()
      }
    end

    test "go with the Fix findings as one note, the diff's then the screens', numbered, and are learned from", %{
      task: %{id: task_id} = task,
      run: %{id: run_id} = run,
      crash: crash,
      nit: nit,
      ada: ada,
      grace: grace,
      diff: diff,
      head: head
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, %{id: screen_id}} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Fold it."})
      {:ok, %{id: diff_id}} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))
      {:ok, %{id: graces_id}} = Pipeline.create_diff_comment(grace, task, Map.put(diff, :body, "Grace's."))
      Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task.id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task.id}:#{ada.user.id}")
      picture = Path.join([task.scratch_path, "qa", "screens/file-list/1.jpg"])

      expect(Tools, :start_os_process, fn %Run{id: ^run_id, status: :running} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "Start fix round 1. The human ruled these 1 findings Fix"
        assert prompt =~ "Their 2 comments follow the findings."
        assert prompt =~ ~s(<finding key="nil-crash")
        assert prompt =~ "1. On the diff:\n<diff_comment>\nlib/a.ex, line 3\n+ x = 1\nName it.\n</diff_comment>"

        assert prompt =~
                 "2. On a screen:\n<screen_comment>\nFile list (file-list), commented on #{String.slice(head, 0, 7)}\n" <>
                   "Picture: #{picture}\nFold it.\n</screen_comment>"

        refute prompt =~ "Grace's."

        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{id: ^run_id}} = Pipeline.start_fix_round(ada, run)

      assert [%DiffComment{id: ^diff_id, status: :sent}, %DiffComment{id: ^graces_id, status: :unsent}] =
               Pipeline.list_diff_comments(grace, task)

      assert [%DiffComment{id: ^diff_id, status: :sent, user: %{login: "ada-start-fix-round"}}] =
               Pipeline.list_diff_comments(system_scope(), task)

      assert %ScreenComment{status: :sent} = Repo.get!(ScreenComment, screen_id)
      assert Pipeline.list_screen_comments(ada, task) == []
      assert [%DiffComment{id: ^graces_id}] = Pipeline.list_diff_comments(grace, task, unsent: true)

      assert [:diff_comment, :review_finding, :screen_comment] =
               Repo.all(
                 from o in Observation, where: o.task_id == ^task.id, select: o.source_kind, order_by: o.source_kind
               )

      assert_received {:diff_comments_changed, ^task_id}
      assert_received {:screen_comments_changed, ^task_id}

      assert [_note | _rest] =
               run |> Pipeline.list_run_events() |> Enum.filter(&(&1.line =~ "[human] 2. On a screen:"))
    end

    # The tray lists finding comments first among the comments, so the note numbers them the same.
    test "finding comments go after the Fix findings and before the diff's and the screens', numbered as the tray does",
         %{
           task: %{id: task_id} = task,
           run: %{id: run_id} = run,
           crash: crash,
           nit: nit,
           ada: ada,
           grace: grace,
           diff: diff
         } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _comment} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Fold it."})
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))

      {:ok, %{id: on_nit_id}} =
        Pipeline.create_finding_comment(ada, task, %{"finding_id" => nit.id, "piece" => "title", "body" => "Not a nit."})

      {:ok, %{id: on_place_id}} =
        Pipeline.create_finding_comment(ada, task, %{
          "finding_id" => crash.id,
          "piece" => "place",
          "index" => 0,
          "body" => "And its caller."
        })

      {:ok, _theirs} =
        Pipeline.create_finding_comment(grace, task, %{"finding_id" => crash.id, "piece" => "fix", "body" => "Grace's."})

      assert [%FindingComment{id: ^on_nit_id}, %FindingComment{id: ^on_place_id}] =
               Pipeline.list_finding_comments(ada, task)

      Phoenix.PubSub.subscribe(Rail.PubSub, "finding_comments:#{task_id}:#{ada.user.id}")

      # Each marker is found after the one before it: the Fix finding, then each comment's number, key and body.
      expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, ["-p", prompt | _rest] ->
        Enum.reduce(
          [
            "Nil crashes the page",
            "lib/b.ex:9",
            "\n1. ",
            "a-nit",
            "Not a nit.",
            "\n2. ",
            "nil-crash",
            "Place 1, handle/1",
            "lib/a.ex:3",
            "And its caller.",
            "\n3. ",
            "Name it.",
            "\n4. ",
            "Fold it."
          ],
          0,
          fn marker, from ->
            assert {at, length} = :binary.match(prompt, marker, scope: {from, byte_size(prompt) - from})
            at + length
          end
        )

        refute prompt =~ "Grace's."
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{id: ^run_id}} = Pipeline.start_fix_round(ada, run)
      assert %FindingComment{status: :sent} = Repo.get!(FindingComment, on_place_id)
      assert Pipeline.list_finding_comments(ada, task) == []
      assert [%FindingComment{body: "Grace's.", status: :unsent}] = Pipeline.list_finding_comments(grace, task)
      assert_received {:finding_comments_changed, ^task_id}

      assert [%Observation{source_kind: :finding_comment}, %Observation{source_kind: :finding_comment}] =
               Repo.all(from o in Observation, where: o.task_id == ^task_id and o.source_kind == :finding_comment)
    end

    # The database's collation puts acme_web before acme/, which byte order does not.
    test "diff comments go in the order the tray lists them", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

      {:ok, _comment} =
        Pipeline.create_diff_comment(ada, task, Map.put(%{diff | path: "lib/acme_web/live/tray_live.ex"}, :body, "Web."))

      {:ok, _comment} =
        Pipeline.create_diff_comment(ada, task, Map.put(%{diff | path: "lib/acme/worker.ex"}, :body, "Worker."))

      tray =
        ada
        |> Pipeline.list_diff_comments(task, unsent: true)
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {comment, n} ->
          "#{n}. On the diff:\n<diff_comment>\n#{comment.path}, line 3\n+ x = 1\n#{comment.body}\n</diff_comment>"
        end)

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ tray
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{}} = Pipeline.start_fix_round(ada, run)
    end

    test "finding comments alone start a fix round", %{task: task, run: run, crash: crash, nit: nit, ada: ada} do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

      {:ok, _comment} =
        Pipeline.create_finding_comment(ada, task, %{"finding_id" => crash.id, "piece" => "why", "body" => "It does."})

      # The comment's key, ruling, piece, quote and body, in that order, and no Fix finding's own fix.
      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        Enum.reduce(["\n1. ", "nil-crash", "Don't fix", "Why fix", "It crashes.", "It does."], 0, fn marker, from ->
          assert {at, length} = :binary.match(prompt, marker, scope: {from, byte_size(prompt) - from})
          at + length
        end)

        refute prompt =~ "Guard it."
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{status: :running}} = Pipeline.start_fix_round(ada, run)
      assert [%{finished_at: nil}] = Pipeline.read_review(task)
    end

    # Nothing delivers the note a failed start leaves, so its comments wait to be sent again.
    test "a lead that cannot be spawned puts its comments back unsent and learns nothing, its rulings included", %{
      project: project,
      task: %{id: task_id} = task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      %{id: rule_id} = learning(project, %{rule: "Don't flag a nil clause", kind: :calibration})

      {:ok, %Finding{suppressed_by_id: ^rule_id} = suppressed} =
        Pipeline.save_finding(task, %{
          key: "nil-clause",
          title: "A nil clause is missing",
          kind: :code,
          raised_by: :code_reviewer,
          problem: "It crashes.",
          file: "lib/a.ex",
          line: 3,
          fix: "Guard it.",
          why: "It crashes.",
          rule: "Every caller handles nil.",
          severity: :minor,
          recommendation: :fix,
          checklist_rule: rule_id,
          places: [%{file: "lib/a.ex", line: 3}],
          evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
        })

      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), suppressed, :fix)

      {:ok, %{id: comment_id}} =
        Pipeline.create_finding_comment(ada, task, %{"finding_id" => crash.id, "piece" => "rule", "body" => "Too wide."})

      {:ok, %{id: diff_id}} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))
      {:ok, %{id: screen_id}} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Fold it."})
      Phoenix.PubSub.subscribe(Rail.PubSub, "finding_comments:#{task_id}:#{ada.user.id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:#{ada.user.id}")

      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
        {:error, {:spawn_failed, :enoent, %{spawned | error: "Could not start"}}}
      end)

      assert {:ok, %Run{error: "Could not start"}} = Pipeline.start_fix_round(ada, run)
      assert [%FindingComment{id: ^comment_id, status: :unsent}] = Pipeline.list_finding_comments(ada, task)
      assert [%DiffComment{id: ^diff_id, status: :unsent}] = Pipeline.list_diff_comments(ada, task, unsent: true)
      assert [%ScreenComment{id: ^screen_id, status: :unsent}] = Pipeline.list_screen_comments(ada, task)
      refute Repo.exists?(from o in Observation, where: o.task_id == ^task_id)
      refute Repo.exists?(from p in LearningProposal, where: p.learning_id == ^rule_id)
      assert_received {:finding_comments_changed, ^task_id}
      assert_received {:diff_comments_changed, ^task_id}
      assert_received {:screen_comments_changed, ^task_id}
    end

    test "comments alone start a fix round, and one written before a retake points at the picture there is", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _comment} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Fold it."})
      git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Retake"])
      retaken = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()
      File.write!(Path.join([task.scratch_path, "qa", "screens/file-list/2.jpg"]), "jpeg")
      {:ok, _shot} = Pipeline.save_screen(task, %{key: "file-list", label: "File list", file: "screens/file-list/2.jpg"})
      picture = Path.join([task.scratch_path, "qa", "screens/file-list/2.jpg"])

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "Start fix round 1 on the human's 1 comment. Nothing is ruled Fix this time"
        assert prompt =~ "Picture: #{picture}, retaken on #{String.slice(retaken, 0, 7)}\n"
        refute prompt =~ "<finding"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{status: :running}} = Pipeline.start_fix_round(ada, run)
      assert [%{finished_at: nil}] = Pipeline.read_review(task)
    end

    test "an empty tray finishes the review and leaves everyone's unsent comments where they are", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      grace: grace,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _theirs} = Pipeline.create_diff_comment(grace, task, Map.put(diff, :body, "Grace's."))
      {:ok, _theirs} = Pipeline.create_screen_comment(grace, task, %{"key" => "file-list", "body" => "Grace's."})
      reject(Tools, :start_os_process, 2)

      Req.Test.expect(Client, 3, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} -> Req.Test.json(conn, %{"token" => "ghs_token"})
          {"GET", "/repos/example/test-seed/pulls/9"} -> Req.Test.json(conn, %{"number" => 9, "node_id" => "PR_9"})
          {"POST", "/graphql"} -> Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
        end
      end)

      assert {:ok, %Run{status: :finished}} = Pipeline.start_fix_round(ada, run)
      assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
      assert [%DiffComment{status: :unsent}] = Pipeline.list_diff_comments(grace, task, unsent: true)
      assert [%ScreenComment{status: :unsent}] = Pipeline.list_screen_comments(grace, task)
    end

    # Comments stay open until cleanup, and past Review they resume the lead without moving the task.
    test "after Finish review, at Finalize, a Send of comments resumes the lead on them, leaves the stage and unmarks ready",
         %{
           task: task,
           run: run,
           crash: crash,
           nit: nit,
           ada: ada,
           grace: grace,
           diff: diff
         } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _finished} = Pipeline.update_task(task, %{pr_number: nil})
      {:ok, %Run{status: :finished}} = Pipeline.start_fix_round(ada, run)
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))

      assert {:error, :nothing_to_start} = Pipeline.start_fix_round(grace, run)

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "Start fix round 1 on the human's 1 comment."
        {:ok, %OsProcess{run: spawned}}
      end)

      {:ok, _marked} =
        Pipeline.update_task(task, %{marked_ready_at: DateTime.utc_now(), marked_ready_by_id: grace.user.id})

      assert {:ok, %Run{status: :running, completed_at: nil}} = Pipeline.start_fix_round(ada, run)
      assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
      # Changes are coming, so the teammate's mark no longer holds.
      assert %Task{stage: :finalize, marked_ready_at: nil, marked_ready_by_id: nil} = Repo.reload!(task)
    end

    # The merged branch stays until cleanup, so a comment still reaches the lead, whose commits only go onto it.
    test "after the merge a Send of comments resumes the lead and the task stays merged, and an empty one is refused",
         %{task: task, run: run, ada: ada, diff: diff} do
      {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})

      # Merged with its last pass still open, the review is over all the same: an empty Send finishes nothing.
      assert {:error, :nothing_to_start} = Pipeline.start_fix_round(ada, run)
      assert [%{finished_at: nil}] = Pipeline.read_review(task)

      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Rename it."))

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "on the human's 1 comment."
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{status: :running}} = Pipeline.start_fix_round(ada, run)
      assert %Task{stage: :merged} = Repo.reload!(task)
    end

    # Nobody rules past Review, so a Fix finding a later turn marked not fixed is not sent as one there.
    test "at Finalize a Send carries the comments alone, never a Fix finding", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

      {:ok, _fixed} =
        Pipeline.save_finding(task, %{
          "key" => "nil-crash",
          "status" => "fixed",
          "covered" => [1, 2],
          "test" => %{"file" => "a_test.exs", "name" => "handles nil"},
          "files" => ["lib/a.ex"]
        })

      {:ok, _no_pr} = Pipeline.update_task(task, %{pr_number: nil})
      {:ok, %Run{status: :finished}} = Pipeline.start_fix_round(ada, run)
      assert %Task{stage: :finalize} = finalizing = Repo.reload!(task)
      {:ok, _noted} = Pipeline.save_finding(finalizing, %{"key" => "nil-crash", "status" => "not_fixed"})
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "on the human's 1 comment."
        refute prompt =~ "<finding"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{status: :running}} = Pipeline.start_fix_round(ada, run)
    end

    test "nothing goes while the review agent works, and the comments stay unsent", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))
      reject(Tools, :start_os_process, 2)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _working} = Pipeline.update_run(run, %{status: :running})

      assert {:error, :stage_running} = Pipeline.start_fix_round(ada, run)
      assert [%DiffComment{status: :unsent}] = Pipeline.list_diff_comments(ada, task)
    end

    test "with dispatch off the comments go back to unsent and nothing is learned", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))
      {:ok, _comment} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Fold it."})

      {:ok, _comment} =
        Pipeline.create_finding_comment(ada, task, %{"finding_id" => crash.id, "piece" => "fix", "body" => "Higher."})

      expect(Tools, :start_os_process, fn %Run{}, _argv -> {:error, :dispatch_disabled} end)

      {:ok, %Run{completed_at: completed_at} = run} =
        Pipeline.update_run(run, %{stage_outcome: :in_progress, error: "The turn stopped."})

      assert {:error, :dispatch_disabled} = Pipeline.start_fix_round(ada, run)

      # The run reads as it did before the Send, not as a fix round that never started.
      assert %Run{status: :finished, stage_outcome: :in_progress, error: "The turn stopped.", completed_at: ^completed_at} =
               Repo.reload!(run)

      assert [%DiffComment{status: :unsent}] = Pipeline.list_diff_comments(ada, task)
      assert [%ScreenComment{status: :unsent}] = Pipeline.list_screen_comments(ada, task)
      assert [%FindingComment{status: :unsent}] = Pipeline.list_finding_comments(ada, task)
      assert %Run{status: :finished} = Repo.reload!(run)
      refute Repo.exists?(from o in Observation, where: o.task_id == ^task.id)
    end

    # Another Send moving the run to running between this one's gate and its own move is the race.
    test "a Send that loses the race to another finds the stage running and gets its comments back", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))
      reject(Tools, :start_os_process, 2)

      expect(Roles, :get_role, fn opts ->
        {:ok, _won} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :running})
        call_original(Roles, :get_role, [opts])
      end)

      assert {:error, :stage_running} = Pipeline.start_fix_round(ada, run)
      assert [%DiffComment{status: :unsent}] = Pipeline.list_diff_comments(ada, task)
      refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "Start fix round"))
    end
  end

  describe "the fix plan" do
    setup %{task: task} do
      {:ok, ada} =
        Users.register_oauth_user(%{
          github_id: "gh_sfr_plan",
          login: "ada-start-fix-round",
          email: "ada-plan@example.com"
        })

      %{
        ada: user_scope(user: ada),
        diff: %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "x = 1", filter: :branch},
        task: Repo.preload(task, :issue)
      }
    end

    test "a Send of two Fix findings and a diff comment asks the lead for a plan only and writes the round's snapshot",
         %{task: task, run: run, crash: crash, nit: nit, ada: ada, diff: diff} do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :fix)
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))
      head = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "Sent 2 findings and 1 comment.\n\nStart fix round 1."
        assert prompt =~ ~s(<finding key="nil-crash")
        assert prompt =~ ~s(<finding key="a-nit")
        assert prompt =~ "1. On the diff:"
        # A planning turn merges nothing in.
        assert %FixPlan{plan: nil} = Pipeline.read_fix_plan(task)
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{status: :running}} = Pipeline.start_fix_round(ada, run)

      assert %FixPlan{
               round: 1,
               head: ^head,
               plan: nil,
               version: 0,
               findings: [
                 %FixPlan.Finding{key: "nil-crash", title: "Nil crashes the page"},
                 %FixPlan.Finding{key: "a-nit", title: "A nit"}
               ],
               comments: [%FixPlan.Comment{number: 1, kind: :diff, place: "a.ex:3", text: "Name it."}]
             } = Pipeline.read_fix_plan(task)
    end

    test "a Send of comments alone gets a plan at Review, at Finalize and after the merge", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

      for stage <- [:review, :finalize, :merged] do
        {:ok, _staged} = Pipeline.update_task(task, %{stage: stage})
        {:ok, _idle} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
        File.rm_rf!(Path.join(task.scratch_path, "fix_plans"))
        {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "At #{stage}."))

        expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
          assert prompt =~ "Sent 1 comment."
          {:ok, %OsProcess{run: spawned}}
        end)

        assert {:ok, %Run{}} = Pipeline.start_fix_round(ada, run)

        assert %FixPlan{findings: [], comments: [%FixPlan.Comment{number: 1, text: "At " <> _stage}]} =
                 Pipeline.read_fix_plan(task)
      end
    end

    test "while a plan waits, a Send carries only what changed and leaves the plan revising", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "Name it."))
      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _started} = Pipeline.start_fix_round(ada, run)

      plan = "### What changes\n\n#### `nil-crash`\n\nGuard it.\n\n#### Comment 1\n\nNamed."
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})

      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :fix)
      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "And this."))

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "Sent 2 changed rulings and 1 comment."
        assert prompt =~ ~s(<ruling_change key="nil-crash" was="Fix" now="Don't fix">\nNil crashes the page)
        assert prompt =~ ~s(<ruling_change key="a-nit" was="Don't fix" now="Fix">)
        assert prompt =~ ~s(<finding key="a-nit")
        refute prompt =~ ~s(<finding key="nil-crash")
        assert prompt =~ "2. On the diff:"
        refute prompt =~ "Name it."
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{status: :running}} = Pipeline.start_fix_round(ada, run)

      assert %FixPlan{
               plan: ^plan,
               version: 1,
               findings: [%FixPlan.Finding{key: "a-nit"}],
               comments: [%FixPlan.Comment{number: 1}, %FixPlan.Comment{number: 2, text: "And this."}]
             } = fix_plan = Pipeline.read_fix_plan(task)

      assert FixPlan.state(fix_plan, task, Pipeline.list_findings(task)) == :revising
      # The newly Fix ruling is learned from as it is delivered.
      assert Repo.exists?(from o in Observation, where: o.source_id == ^nit.id and o.source_kind == :review_finding)
    end

    test "while a plan waits, a Send with nothing changed is refused, Finish review with it, and nothing resumes", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _started} = Pipeline.start_fix_round(ada, run)
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => "### What changes\n\n#### `nil-crash`\n\nGuard it."})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})

      reject(Tools, :start_os_process, 2)
      assert {:error, :fix_plan_waiting} = Pipeline.start_fix_round(ada, run)

      # Changed and changed back is nothing changed.
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      assert {:error, :fix_plan_waiting} = Pipeline.start_fix_round(ada, run)
      assert %Run{status: :finished} = Repo.reload!(run)
    end

    test "a round changed down to nothing ends as Finish review does and leaves no plan", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada
    } do
      {:ok, _no_pr} = Pipeline.update_task(task, %{pr_number: nil})
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _started} = Pipeline.start_fix_round(ada, run)
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => "### What changes\n\n#### `nil-crash`\n\nGuard it."})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)

      assert {:ok, %Run{status: :finished, stage_outcome: :done}} = Pipeline.start_fix_round(ada, run)
      assert %Task{stage: :finalize} = Repo.reload!(task)
      assert Pipeline.read_fix_plan(task) == nil
    end

    test "Finish review on a round with no fix plan writes none", %{task: task, run: run, crash: crash, nit: nit} do
      {:ok, _no_pr} = Pipeline.update_task(task, %{pr_number: nil})
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

      assert {:ok, %Run{status: :finished}} = Pipeline.start_fix_round(system_scope(), run)
      assert Pipeline.read_fix_plan(task) == nil
    end

    test "a failed start puts the round's plan back as it was", %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: ada,
      diff: diff
    } do
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
        {:error, {:spawn_failed, :enoent, %{spawned | error: "Could not start"}}}
      end)

      assert {:ok, %Run{error: "Could not start"}} = Pipeline.start_fix_round(ada, run)
      assert Pipeline.read_fix_plan(task) == nil

      {:ok, _settled} =
        run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done, error: nil})

      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _started} = Pipeline.start_fix_round(ada, run)
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => "### What changes\n\n#### `nil-crash`\n\nGuard it."})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      before = Pipeline.read_fix_plan(task)

      {:ok, _comment} = Pipeline.create_diff_comment(ada, task, Map.put(diff, :body, "And this."))
      expect(Tools, :start_os_process, fn %Run{}, _argv -> {:error, :dispatch_disabled} end)

      assert {:error, :dispatch_disabled} = Pipeline.start_fix_round(ada, run)
      assert Pipeline.read_fix_plan(task) == before
      assert [%DiffComment{status: :unsent}] = Pipeline.list_diff_comments(ada, task, unsent: true)
    end
  end
end
