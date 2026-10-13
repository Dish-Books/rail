defmodule RailWeb.Live.FinalizeStageTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.GitHub.Client
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Users

  setup %{conn: conn, project: project} do
    id = System.unique_integer([:positive])

    register = fn login, attrs ->
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "fst-#{login}-#{id}",
          login: "#{login}-#{id}",
          email: "#{login}-#{id}@fst"
        })

      {:ok, user} = Users.update_user(system_scope(), user, Map.put(attrs, :project_ids, [project.id]))
      user
    end

    dan = register.("dano", %{name: "Dan Okafor"})

    priya =
      register.("priya", %{
        name: "Priya Raman",
        tech_lead: true,
        github_token: "gho_priya",
        github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
      })

    michael = register.("mkerr", %{name: "Michael Kerr", tech_lead: true})

    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    task = learnings_task(project, "FST-1", :review)
    worktree = create_temp_git_repo()
    git!(worktree, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    File.write!(Path.join(worktree, "round.ex"), "one\ntwo\n")
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "Send comments as one round"])

    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_path: worktree,
        pr_number: 151,
        pr_url: "https://github.com/example/test-seed/pull/151",
        pr_is_draft: false
      })

    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_fst_lead",
        started_at: DateTime.utc_now()
      })

    # Saved while the task was at Review, as Finalize takes no pass of its own.
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, task} = Pipeline.update_task(task, %{stage: :finalize})

    # GitHub is asked for approvals as the pane opens past Mark ready; a test about them says what it answers.
    stub(Pipeline, :list_approvals, fn _task -> {:ok, []} end)

    %{conn: conn, task: task, dan: dan, priya: priya, michael: michael}
  end

  test "the pane shows the pull request and Mark ready, and marking says who marked it and when", %{
    conn: conn,
    task: task,
    dan: dan
  } do
    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#finalize-pane[data-state='not_ready']")
    assert has_element?(view, "#finalize-pr", "FST-1 Work on FST-1")
    assert has_element?(view, "#finalize-pr-state", "Open")
    assert has_element?(view, "#finalize-pr", "#151")
    assert has_element?(view, "#finalize-pr", task.worktree_name)
    assert has_element?(view, "#finalize-pr-link[href='https://github.com/example/test-seed/pull/151']")
    assert has_element?(view, "#finalize-commits", ~r/^\s*1\s+\+2\s+−0\s*$/)
    assert has_element?(view, "#finalize-review", "Finished in 1 round · 0 fixed · 0 not fixing")
    refute has_element?(view, "#finalize-marked")
    refute has_element?(view, "#finalize-merge")

    view |> element("#finalize-mark-ready") |> render_click()

    assert has_element?(view, "#finalize-pane[data-state='ready']")
    assert has_element?(view, "#finalize-marked", "Marked ready by Dan Okafor at")
    assert has_element?(view, "#finalize-marked time[datetime]")
    refute has_element?(view, "#finalize-mark-ready")
    assert has_element?(view, "[data-qa='task_status_chip']", "Ready for tech lead")
  end

  test "a teammate without the setting sees who to wait for and no Merge", %{conn: conn, task: task, dan: dan} do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#finalize-waiting", "Waiting for a tech lead: Michael Kerr or Priya Raman")
    refute has_element?(view, "#finalize-merge")
  end

  test "the waiting line names the one tech lead there is, or says only that it waits when there is none", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(system_scope(), task)
    {:ok, _off} = Users.update_user(system_scope(), priya, %{tech_lead: false})
    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#finalize-marked", "Marked ready by someone at")
    assert has_element?(view, "#finalize-waiting", ~r/Waiting for a tech lead: Michael Kerr\s*$/)

    for lead <- Users.list_tech_leads(task.project_id),
        do: {:ok, _off} = Users.update_user(system_scope(), lead, %{tech_lead: false})

    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#finalize-waiting", ~r/Waiting for a tech lead\s*$/)
  end

  test "a tech lead sees Merge, squashing into the default branch", %{conn: conn, task: task, dan: dan, priya: priya} do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#finalize-merge:not([disabled])", "Merge")
    assert has_element?(view, "#finalize-pane", "Squash into main")
    refute has_element?(view, "#finalize-waiting")
  end

  test "a refusal shows GitHub's reason above Merge, which stays to try again", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)

    Req.Test.expect(Client, 3, fn conn ->
      case conn.method do
        "PUT" ->
          conn
          |> Plug.Conn.put_status(405)
          |> Req.Test.json(%{"message" => ~s{Required status check "test (1.18, 27)" is failing.}})

        "POST" ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        "GET" ->
          Req.Test.json(conn, %{"number" => 151, "merged" => false, "merge_commit_sha" => nil})
      end
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#finalize-merge") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-pane[data-state='refused']")
      assert has_element?(view, "#finalize-merge-error[role='alert']", "GitHub refused the merge at")
      assert has_element?(view, "#finalize-merge-error", ~s{Required status check "test (1.18, 27)" is failing.})
      assert has_element?(view, "#finalize-merge-error + #finalize-marked")
      assert has_element?(view, "#finalize-merge:not([disabled])", "Merge")
      refute has_element?(view, "#finalize-error")
    end)

    assert %Task{stage: :finalize, merged_at: nil} = Repo.reload!(task)
  end

  test "a merge shows the merged line with who merged it and the short sha", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    Req.Test.expect(Client, &Req.Test.json(&1, %{"merged" => true, "sha" => "3c9a1f0e2b"}))

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#finalize-merge") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-pane[data-state='merged']")
      assert has_element?(view, "#finalize-pr-state", "Merged")
      assert has_element?(view, "#finalize-merged", "Squash merged into main by Priya Raman at")
      assert has_element?(view, "#finalize-merged", "3c9a1f0")
      refute has_element?(view, "#finalize-merge")
    end)
  end

  # Each is a page drawn before another tab moved the task on, or an event sent past the hidden button.
  test "a mark or a merge the task no longer takes says why", %{conn: conn, task: task, dan: dan, priya: priya} do
    assert {:ok, as_dan, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
    assert {:ok, as_priya, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

    {:ok, task} = Pipeline.update_task(task, %{pr_number: nil})
    as_dan |> element("#finalize-mark-ready") |> render_click()
    assert has_element?(as_dan, "#finalize-error", "This task has no pull request to merge.")

    {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 151})
    as_dan |> element("#finalize-mark-ready") |> render_click()
    assert has_element?(as_dan, "#finalize-error", "This task is at Review, not Finalize.")

    {:ok, task} = Pipeline.update_task(task, %{stage: :finalize})
    as_priya |> with_target("#finalize-stage") |> render_click("merge", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "Mark the task ready before merging it.") end)

    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    as_dan |> with_target("#finalize-stage") |> render_click("merge", %{})
    eventually(fn -> assert has_element?(as_dan, "#finalize-error", "Only a tech lead can merge a task.") end)

    {:ok, merging} = Pipeline.update_task(Repo.reload!(task), %{merge_started_at: DateTime.utc_now()})
    as_priya |> with_target("#finalize-stage") |> render_click("merge", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "A merge is already under way.") end)

    {:ok, _merged} = Pipeline.update_task(merging, %{merge_started_at: nil, merged_at: DateTime.utc_now()})
    as_priya |> with_target("#finalize-stage") |> render_click("merge", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "This task is already merged.") end)
  end

  # A second click while the first merge waits on GitHub sends nothing, and a merge that dies says so.
  test "a second click while merging does nothing, and a merge that dies can be tried again", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    test_pid = self()

    expect(Pipeline, :merge_task, fn _scope, _task ->
      send(test_pid, {:merging, self()})
      receive do: (:die -> exit(:github_went_away))
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#finalize-merge") |> render_click()
    assert_receive {:merging, merge}, 2_000
    view |> with_target("#finalize-stage") |> render_click("merge", %{})

    send(merge, :die)

    eventually(fn ->
      assert has_element?(view, "#finalize-error", "The merge did not finish. Try again.")
      assert has_element?(view, "#finalize-merge:not([disabled])", "Merge")
    end)
  end

  test "a tech lead's Approve approves as them on GitHub, and their approval takes the button's place", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    stub(Pipeline, :list_approvals, &Mimic.call_original(Pipeline, :list_approvals, [&1]))

    # Approvals given on GitHub: Dan's under his Rail name, and one from someone with no Rail account.
    {:ok, reviews} =
      Agent.start_link(fn ->
        [
          %{
            "user" => %{"login" => "jkowalski-dev-finalize-stage"},
            "state" => "APPROVED",
            "submitted_at" => "2026-10-10T16:02:00Z"
          },
          %{"user" => %{"login" => dan.login}, "state" => "APPROVED", "submitted_at" => "2026-10-11T14:31:00Z"}
        ]
      end)

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", "/repos/example/test-seed/pulls/151/reviews"} ->
          Req.Test.json(conn, Agent.get(reviews, & &1))

        {"POST", "/repos/example/test-seed/pulls/151/reviews"} ->
          assert ["Bearer gho_priya"] = Plug.Conn.get_req_header(conn, "authorization")
          review = %{"user" => %{"login" => priya.login}, "state" => "APPROVED"}
          Agent.update(reviews, &[Map.put(review, "submitted_at", "2026-10-11T14:40:00Z") | &1])
          Req.Test.json(conn, Map.put(review, "id", 80))
      end
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    assert has_element?(
             view,
             "#finalize-approvals #finalize-approval-jkowalski-dev-finalize-stage .font-mono",
             "jkowalski-dev-finalize-stage"
           )

    assert has_element?(view, "#finalize-approval-#{dan.login}", "Dan Okafor")
    assert has_element?(view, "#finalize-approval-#{dan.login} time[datetime]")
    assert has_element?(view, "#finalize-actions.flex-wrap > #finalize-approve:not([disabled])", "Approve")
    assert has_element?(view, "#finalize-actions > .flex-wrap > #finalize-merge", "Merge")

    view |> element("#finalize-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-actions > #finalize-approved", "Approved by Priya Raman at")
      assert has_element?(view, "#finalize-approved time[datetime='2026-10-11T14:40:00Z']")
      assert has_element?(view, "#finalize-approval-#{priya.login}", "Priya Raman")
      refute has_element?(view, "#finalize-approve")
      assert has_element?(view, "#finalize-merge:not([disabled])")
    end)
  end

  test "a refusal shows GitHub's message above Approve, lists no approval from the lead, and leaves Merge", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    stub(Pipeline, :list_approvals, &Mimic.call_original(Pipeline, :list_approvals, [&1]))

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", _reviews} ->
          Req.Test.json(conn, [])

        {"POST", _reviews} ->
          conn
          |> Plug.Conn.put_status(422)
          |> Req.Test.json(%{
            "message" => "Unprocessable Entity",
            "errors" => ["Can not approve your own pull request"]
          })
      end
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#finalize-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-approve-error[role='alert']", "GitHub refused the approval at")
      assert has_element?(view, "#finalize-approve-error time[datetime]")
      assert has_element?(view, "#finalize-approve-error", "Unprocessable Entity: Can not approve your own pull request")
      assert has_element?(view, "#finalize-approve-error + #finalize-marked")
      assert has_element?(view, "#finalize-approve:not([disabled])", "Approve")
      assert has_element?(view, "#finalize-merge:not([disabled])", "Merge")
      refute has_element?(view, "#finalize-approvals")
      refute has_element?(view, "#finalize-approve-sign-in")
      refute has_element?(view, "#finalize-error")
    end)
  end

  test "an approval that never heard back is not called a refusal, and one GitHub took shows though its read failed", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    stub(Pipeline, :list_approvals, &Mimic.call_original(Pipeline, :list_approvals, [&1]))
    {:ok, github} = Agent.start_link(fn -> %{reviews: [], reads: 0, posts: 0} end)

    # The first post times out; the second is taken, and the read just after it fails.
    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", _reviews} ->
          %{reviews: reviews, reads: reads, posts: posts} =
            Agent.get_and_update(github, &{&1, %{&1 | reads: &1.reads + 1}})

          if posts == 2 and reads == 3,
            do: conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{}),
            else: Req.Test.json(conn, reviews)

        {"POST", _reviews} ->
          %{posts: posts} = Agent.get_and_update(github, &{&1, %{&1 | posts: &1.posts + 1}})

          if posts == 0 do
            Req.Test.transport_error(conn, :timeout)
          else
            review = %{"user" => %{"login" => priya.login}, "state" => "APPROVED"}
            review = Map.put(review, "submitted_at", "2026-10-11T14:40:00Z")
            Agent.update(github, &%{&1 | reviews: [review]})
            Req.Test.json(conn, Map.put(review, "id", 80))
          end
      end
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)
    view |> element("#finalize-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-error", "The approval did not finish. Try again.")
      assert has_element?(view, "#finalize-approve:not([disabled])", "Approve")
      refute has_element?(view, "#finalize-approve-error")
    end)

    view |> element("#finalize-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-approved", "Approved by Priya Raman at")
      assert has_element?(view, "#finalize-approval-#{priya.login}", "Priya Raman")
      refute has_element?(view, "#finalize-error")
      refute has_element?(view, "#finalize-approve-error")
    end)
  end

  test "a tech lead with no GitHub token is told to sign in again", %{
    conn: conn,
    task: task,
    dan: dan,
    michael: michael
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, michael), ~p"/tasks/#{task.id}")

    view |> element("#finalize-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-approve-error[role='alert']", "Sign in with GitHub again to approve")
      assert has_element?(view, "#finalize-approve-error", "Rail holds no GitHub token for you, so nothing was sent.")
      assert has_element?(view, "#finalize-approve-sign-in[href='/auth/github']", "Sign in with GitHub")
      refute has_element?(view, "#finalize-approve-error time")
    end)
  end

  test "a tech lead with no GitHub token who merges is told to sign in again, and Merge stays", %{
    conn: conn,
    task: task,
    dan: dan,
    michael: michael
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, michael), ~p"/tasks/#{task.id}")

    view |> element("#finalize-merge") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#finalize-error", "Sign in with GitHub again to merge")
      assert has_element?(view, "#finalize-merge")
    end)
  end

  test "a teammate or an admin without the setting sees the approvals and the waiting line, and no Approve", %{
    conn: conn,
    task: task,
    dan: dan
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)

    stub(Pipeline, :list_approvals, fn _task ->
      {:ok, [%{login: "jkowalski-dev-finalize-stage", user: nil, approved_at: ~U[2026-10-10 16:02:00Z]}]}
    end)

    {:ok, admin} =
      Users.register_oauth_user(%{github_id: "fst-admin", login: "fst-admin", email: "fst-admin@fst"})

    {:ok, admin} =
      Users.update_user(system_scope(), admin, %{
        admin: true,
        github_token: "gho_admin",
        github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
      })

    for viewer <- [dan, admin] do
      assert {:ok, view, _html} = live(log_in_user(conn, viewer), ~p"/tasks/#{task.id}")
      render_async(view)

      assert has_element?(view, "#finalize-approval-jkowalski-dev-finalize-stage", "jkowalski-dev-finalize-stage")
      assert has_element?(view, "#finalize-waiting", "Waiting for a tech lead")
      refute has_element?(view, "#finalize-approve")
      refute has_element?(view, "#finalize-actions")
    end
  end

  test "nobody sees Approve or the approvals before Mark ready, and after the merge the approvals stay", %{
    conn: conn,
    task: task,
    priya: priya
  } do
    stub(Pipeline, :list_approvals, fn _task ->
      {:ok, [%{login: "jkowalski-dev-finalize-stage", user: nil, approved_at: ~U[2026-10-10 16:02:00Z]}]}
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    assert has_element?(view, "#finalize-mark-ready")
    refute has_element?(view, "#finalize-approve")
    refute has_element?(view, "#finalize-approvals")

    {:ok, _merged} =
      Pipeline.update_task(task, %{
        stage: :merged,
        marked_ready_at: DateTime.utc_now(),
        merged_at: DateTime.utc_now(),
        merge_sha: "3c9a1f0e2b"
      })

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}?tab=finalize")
    render_async(view)

    assert has_element?(view, "#finalize-merged")
    assert has_element?(view, "#finalize-approval-jkowalski-dev-finalize-stage")
    refute has_element?(view, "#finalize-approve")
    refute has_element?(view, "#finalize-approved")
  end

  test "with no approvals, or a read GitHub failed, the card has no Approvals row and says nothing", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    refute has_element?(view, "#finalize-approvals")
    assert has_element?(view, "#finalize-approve")

    stub(Pipeline, :list_approvals, fn _task -> {:error, {:github_api_error, 502, %{}}} end)
    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    refute has_element?(view, "#finalize-approvals")
    refute has_element?(view, "#finalize-error")
    assert has_element?(view, "#finalize-approve")
  end

  test "the pane draws before GitHub answers the approvals read", %{conn: conn, task: task, dan: dan, priya: priya} do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    test_pid = self()

    stub(Pipeline, :list_approvals, fn _task ->
      send(test_pid, {:reading, self()})
      assert_receive :answer, 2_000
      {:ok, [%{login: "jkowalski-dev-finalize-stage", user: nil, approved_at: ~U[2026-10-10 16:02:00Z]}]}
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    assert_receive {:reading, github}, 2_000

    assert has_element?(view, "#finalize-pr", "#151")
    assert has_element?(view, "#finalize-approve")
    refute has_element?(view, "#finalize-approvals")

    send(github, :answer)
    eventually(fn -> assert has_element?(view, "#finalize-approval-jkowalski-dev-finalize-stage") end)
  end

  # A second click while the first approval waits on GitHub sends nothing, and Merge stays to click meanwhile.
  test "a second click while approving does nothing, and an approval that dies can be tried again", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    test_pid = self()

    expect(Pipeline, :approve_task, fn _scope, _task ->
      send(test_pid, {:approving, self()})
      receive do: (:die -> exit(:github_went_away))
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#finalize-approve") |> render_click()
    assert_receive {:approving, approval}, 2_000

    assert has_element?(view, "#finalize-approve[disabled]", "Approving…")
    assert has_element?(view, "#finalize-merge:not([disabled])", "Merge")
    view |> with_target("#finalize-stage") |> render_click("approve", %{})
    refute_received {:approving, _second}

    send(approval, :die)

    eventually(fn ->
      assert has_element?(view, "#finalize-error", "The approval did not finish. Try again.")
      assert has_element?(view, "#finalize-approve:not([disabled])", "Approve")
    end)
  end

  # Each is a page drawn before another tab moved the task on, or an event sent past the hidden button.
  test "an approval the task no longer takes says why", %{conn: conn, task: task, dan: dan, priya: priya} do
    assert {:ok, as_dan, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
    assert {:ok, as_priya, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

    as_priya |> with_target("#finalize-stage") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "Mark the task ready before approving it.") end)

    {:ok, task} = Pipeline.mark_ready(Rail.Scope.for_user(dan), task)
    as_dan |> with_target("#finalize-stage") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_dan, "#finalize-error", "Only a tech lead can approve a task.") end)

    stub(Pipeline, :list_approvals, fn _task -> {:error, {:github_api_error, 502, %{}}} end)
    as_priya |> with_target("#finalize-stage") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "The approval did not finish. Try again.") end)

    {:ok, task} = Pipeline.update_task(task, %{pr_number: nil})
    as_priya |> with_target("#finalize-stage") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "no pull request to approve.") end)

    {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 151})
    as_priya |> with_target("#finalize-stage") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "This task is at Review, not Finalize.") end)

    {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})
    as_priya |> with_target("#finalize-stage") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#finalize-error", "This task is already merged.") end)
  end
end
