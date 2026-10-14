defmodule RailWeb.Live.TaskActionsTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users
  alias RailWeb.Live.TaskActions

  setup %{conn: conn, project: project} do
    id = System.unique_integer([:positive])

    register = fn login, attrs ->
      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "tat-#{login}-#{id}",
          login: "#{login}-#{id}",
          email: "#{login}-#{id}@tat"
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
    task = learnings_task(project, "TAT-1", :review)
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
        conversation_id: "sess_tat_lead",
        started_at: DateTime.utc_now()
      })

    # Saved while the task was at Review, as Finalize takes no pass of its own.
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, task} = Pipeline.update_task(task, %{stage: :finalize})

    # GitHub is asked for approvals as the header opens past Ready for review; a test about them says what it answers.
    stub(Pipeline, :list_approvals, fn _task -> {:ok, []} end)

    %{conn: conn, task: task, dan: dan, priya: priya, michael: michael}
  end

  test "Ready for review marks the task ready, and the header then waits on a tech lead", %{
    conn: conn,
    task: task,
    dan: %{id: dan_id} = dan
  } do
    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-actions #task-ready-for-review", "Ready for review")
    refute has_element?(view, "#task-waiting")
    refute has_element?(view, "#task-merge")

    view |> element("#task-ready-for-review") |> render_click()

    refute has_element?(view, "#task-ready-for-review")
    assert has_element?(view, "#task-waiting", "Waiting for a tech lead: Michael Kerr or Priya Raman")
    assert has_element?(view, "[data-qa='task_status_chip']", "Ready for tech lead")
    assert %Task{marked_ready_by_id: ^dan_id} = Repo.reload!(task)
  end

  test "a teammate without the setting sees who to wait for and no Merge", %{conn: conn, task: task, dan: dan} do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-waiting", "Waiting for a tech lead: Michael Kerr or Priya Raman")
    refute has_element?(view, "#task-approve")
    refute has_element?(view, "#task-merge")
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

    assert has_element?(view, "#task-waiting", ~r/Waiting for a tech lead: Michael Kerr\s*$/)

    for lead <- Users.list_tech_leads(task.project_id),
        do: {:ok, _off} = Users.update_user(system_scope(), lead, %{tech_lead: false})

    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-waiting", ~r/Waiting for a tech lead\s*$/)
  end

  test "a tech lead sees Approve and Merge, squashing into the default branch", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-approve:not([disabled])", "Approve")
    assert has_element?(view, "#task-merge[title='Squash into main']:not([disabled])", "Merge")
    refute has_element?(view, "#task-waiting")
  end

  test "a refusal shows GitHub refused the merge, its reason on hover, and Merge stays to try again", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)

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
    view |> element("#task-merge") |> render_click()

    eventually(fn ->
      assert has_element?(
               view,
               ~s{#task-merge-error[role='alert'][title='Required status check "test (1.18, 27)" is failing.']},
               "GitHub refused the merge"
             )

      assert has_element?(view, "#task-merge:not([disabled])", "Merge")
      refute has_element?(view, "#task-actions-error")
    end)

    assert %Task{stage: :finalize, merged_at: nil} = Repo.reload!(task)
  end

  test "a merge shows who merged it in place of Approve and Merge", %{conn: conn, task: task, dan: dan, priya: priya} do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    Req.Test.expect(Client, &Req.Test.json(&1, %{"merged" => true, "sha" => "3c9a1f0e2b"}))

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#task-merge") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#task-merged", "Merged by Priya Raman")
      refute has_element?(view, "#task-merge")
      refute has_element?(view, "#task-approve")
      refute has_element?(view, "#task-actions-error")
    end)
  end

  # Each is a page drawn before another tab moved the task on, or an event sent past the hidden button.
  test "a mark or a merge the task no longer takes says why", %{conn: conn, task: task, dan: dan, priya: priya} do
    assert {:ok, as_dan, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
    assert {:ok, as_priya, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    as_dan |> element("#task-ready-for-review") |> render_click()
    assert has_element?(as_dan, "#task-actions-error[role='alert']", "This task is at Review.")

    {:ok, task} = Pipeline.update_task(task, %{stage: :finalize})
    as_priya |> with_target("#task-actions") |> render_click("merge", %{})

    eventually(fn ->
      assert has_element?(as_priya, "#task-actions-error", "Mark the task ready for review before merging it.")
    end)

    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    as_dan |> with_target("#task-actions") |> render_click("merge", %{})
    eventually(fn -> assert has_element?(as_dan, "#task-actions-error", "Only a tech lead can merge a task.") end)

    {:ok, task} = Pipeline.update_task(Repo.reload!(task), %{pr_number: nil, merge_started_at: nil})
    as_priya |> with_target("#task-actions") |> render_click("merge", %{})

    eventually(fn ->
      assert has_element?(as_priya, "#task-actions-error", "This task has no pull request to merge.")
    end)

    {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 151})
    as_priya |> with_target("#task-actions") |> render_click("merge", %{})

    eventually(fn ->
      assert has_element?(as_priya, "#task-actions-error", "This task is at Review, not Finalize.")
    end)

    {:ok, merging} = Pipeline.update_task(task, %{stage: :finalize, merge_started_at: DateTime.utc_now()})
    as_priya |> with_target("#task-actions") |> render_click("merge", %{})
    eventually(fn -> assert has_element?(as_priya, "#task-actions-error", "A merge is already under way.") end)

    {:ok, _merged} = Pipeline.update_task(merging, %{merge_started_at: nil, merged_at: DateTime.utc_now()})
    as_priya |> with_target("#task-actions") |> render_click("merge", %{})
    eventually(fn -> assert has_element?(as_priya, "#task-actions-error", "This task is already merged.") end)
  end

  # A second click while the first merge waits on GitHub sends nothing, and a merge that dies says so.
  test "a second click while merging does nothing, and a merge that dies can be tried again", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    test_pid = self()

    expect(Pipeline, :merge_task, fn _scope, _task ->
      send(test_pid, {:merging, self()})
      receive do: (:die -> exit(:github_went_away))
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#task-merge") |> render_click()
    assert_receive {:merging, merge}, 2_000

    assert has_element?(view, "#task-merge[disabled]", "Merging…")
    view |> with_target("#task-actions") |> render_click("merge", %{})
    refute_received {:merging, _second}

    send(merge, :die)

    eventually(fn ->
      assert has_element?(view, "#task-actions-error", "The merge did not finish. Try again.")
      assert has_element?(view, "#task-merge:not([disabled])", "Merge")
    end)
  end

  test "a tech lead's Approve approves as them on GitHub, and their approval takes the button's place", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    stub(Pipeline, :list_approvals, &Mimic.call_original(Pipeline, :list_approvals, [&1]))

    # Approvals given on GitHub: Dan's under his Rail name, and one from someone with no Rail account.
    {:ok, reviews} =
      Agent.start_link(fn ->
        [
          %{
            "user" => %{"login" => "jkowalski-dev-task-actions"},
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

    assert has_element?(view, "#task-approvals", ~r/Approved by jkowalski-dev-task-actions, Dan Okafor\s*$/)
    refute has_element?(view, "#task-approved")
    assert has_element?(view, "#task-approve:not([disabled])", "Approve")

    view |> element("#task-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#task-approved", "Approved by you")
      assert has_element?(view, "#task-approvals", ~r/Dan Okafor, Priya Raman\s*$/)
      refute has_element?(view, "#task-approve")
      assert has_element?(view, "#task-merge:not([disabled])")
    end)
  end

  test "a refusal shows GitHub's message, lists no approval from the lead, and leaves Approve and Merge", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
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
    view |> element("#task-approve") |> render_click()

    eventually(fn ->
      assert has_element?(
               view,
               "#task-actions-error[role='alert']",
               "GitHub refused the approval: Unprocessable Entity: Can not approve your own pull request"
             )

      assert has_element?(view, "#task-approve:not([disabled])", "Approve")
      assert has_element?(view, "#task-merge:not([disabled])", "Merge")
      refute has_element?(view, "#task-approvals")
      refute has_element?(view, "#task-approved")
    end)
  end

  test "an approval that never heard back is not called a refusal, and one GitHub took shows though its read failed", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
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
    view |> element("#task-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#task-actions-error", "The approval did not finish. Try again.")
      assert has_element?(view, "#task-approve:not([disabled])", "Approve")
    end)

    view |> element("#task-approve") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#task-approved", "Approved by you")
      assert has_element?(view, "#task-approvals", "Approved by Priya Raman")
      refute has_element?(view, "#task-actions-error")
    end)
  end

  test "a tech lead with no GitHub token who approves is told to sign in again", %{
    conn: conn,
    task: task,
    dan: dan,
    michael: michael
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, michael), ~p"/tasks/#{task.id}")

    view |> element("#task-approve") |> render_click()

    eventually(fn ->
      assert has_element?(
               view,
               "#task-actions-error[role='alert']",
               "Sign in with GitHub again to approve. Nothing was sent."
             )

      assert has_element?(view, "#task-approve:not([disabled])")
    end)
  end

  test "a tech lead with no GitHub token who merges is told to sign in again, and Merge stays", %{
    conn: conn,
    task: task,
    dan: dan,
    michael: michael
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, michael), ~p"/tasks/#{task.id}")

    view |> element("#task-merge") |> render_click()

    eventually(fn ->
      assert has_element?(view, "#task-actions-error", "Sign in with GitHub again to merge. Nothing was sent.")
      assert has_element?(view, "#task-merge:not([disabled])")
    end)
  end

  test "a teammate or an admin without the setting sees the approvals and the waiting line, and no Approve", %{
    conn: conn,
    task: task,
    dan: dan
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)

    # One approver with no Rail account, and one whose Rail account has no name.
    stub(Pipeline, :list_approvals, fn _task ->
      {:ok,
       [
         %{login: "jkowalski-dev-task-actions", user: nil, approved_at: ~U[2026-10-10 16:02:00Z]},
         %{login: "rnoname-tat", user: %{name: "", login: "rnoname-tat"}, approved_at: ~U[2026-10-10 16:03:00Z]}
       ]}
    end)

    {:ok, admin} =
      Users.register_oauth_user(%{github_id: "tat-admin", login: "tat-admin", email: "tat-admin@tat"})

    {:ok, admin} =
      Users.update_user(system_scope(), admin, %{
        admin: true,
        github_token: "gho_admin",
        github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
      })

    for viewer <- [dan, admin] do
      assert {:ok, view, _html} = live(log_in_user(conn, viewer), ~p"/tasks/#{task.id}")
      render_async(view)

      assert has_element?(view, "#task-approvals", ~r/Approved by jkowalski-dev-task-actions, rnoname-tat\s*$/)
      assert has_element?(view, "#task-waiting", "Waiting for a tech lead")
      refute has_element?(view, "#task-approve")
      refute has_element?(view, "#task-merge")
    end
  end

  test "nobody sees Approve or the approvals before Ready for review, and after the merge the approvals stay", %{
    conn: conn,
    task: task,
    priya: priya
  } do
    stub(Pipeline, :list_approvals, fn _task ->
      {:ok, [%{login: "jkowalski-dev-task-actions", user: nil, approved_at: ~U[2026-10-10 16:02:00Z]}]}
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    assert has_element?(view, "#task-ready-for-review")
    refute has_element?(view, "#task-approve")
    refute has_element?(view, "#task-approvals")

    # Merged on GitHub, by nobody with a Rail account.
    {:ok, _merged} =
      Pipeline.update_task(task, %{
        stage: :merged,
        marked_ready_at: DateTime.utc_now(),
        merged_at: DateTime.utc_now(),
        merge_sha: "3c9a1f0e2b"
      })

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    assert has_element?(view, "#task-merged", "Merged by someone")
    assert has_element?(view, "#task-approvals", "Approved by jkowalski-dev-task-actions")
    refute has_element?(view, "#task-approve")
    refute has_element?(view, "#task-approved")
    refute has_element?(view, "#task-merge")
  end

  test "with no approvals, or a read GitHub failed, the header lists none and says nothing", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    refute has_element?(view, "#task-approvals")
    assert has_element?(view, "#task-approve")

    stub(Pipeline, :list_approvals, fn _task -> {:error, {:github_api_error, 502, %{}}} end)
    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    render_async(view)

    refute has_element?(view, "#task-approvals")
    refute has_element?(view, "#task-actions-error")
    assert has_element?(view, "#task-approve")
  end

  test "the header draws before GitHub answers the approvals read", %{conn: conn, task: task, dan: dan, priya: priya} do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    test_pid = self()

    stub(Pipeline, :list_approvals, fn _task ->
      send(test_pid, {:reading, self()})
      assert_receive :answer, 2_000
      {:ok, [%{login: "jkowalski-dev-task-actions", user: nil, approved_at: ~U[2026-10-10 16:02:00Z]}]}
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    assert_receive {:reading, github}, 2_000

    assert has_element?(view, "#task-merge")
    assert has_element?(view, "#task-approve")
    refute has_element?(view, "#task-approvals")

    send(github, :answer)
    eventually(fn -> assert has_element?(view, "#task-approvals", "jkowalski-dev-task-actions") end)
  end

  # A second click while the first approval waits on GitHub sends nothing, and Merge stays to click meanwhile.
  test "a second click while approving does nothing, and an approval that dies can be tried again", %{
    conn: conn,
    task: task,
    dan: dan,
    priya: priya
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    test_pid = self()

    expect(Pipeline, :approve_task, fn _scope, _task ->
      send(test_pid, {:approving, self()})
      receive do: (:die -> exit(:github_went_away))
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
    view |> element("#task-approve") |> render_click()
    assert_receive {:approving, approval}, 2_000

    assert has_element?(view, "#task-approve[disabled]", "Approving…")
    assert has_element?(view, "#task-merge:not([disabled])", "Merge")
    view |> with_target("#task-actions") |> render_click("approve", %{})
    refute_received {:approving, _second}

    send(approval, :die)

    eventually(fn ->
      assert has_element?(view, "#task-actions-error", "The approval did not finish. Try again.")
      assert has_element?(view, "#task-approve:not([disabled])", "Approve")
    end)
  end

  # Each is a page drawn before another tab moved the task on, or an event sent past the hidden button.
  test "an approval the task no longer takes says why", %{conn: conn, task: task, dan: dan, priya: priya} do
    assert {:ok, as_dan, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
    assert {:ok, as_priya, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

    as_priya |> with_target("#task-actions") |> render_click("approve", %{})

    eventually(fn ->
      assert has_element?(as_priya, "#task-actions-error", "Mark the task ready for review before approving it.")
    end)

    {:ok, task} = Pipeline.mark_ready(Scope.for_user(dan), task)
    as_dan |> with_target("#task-actions") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_dan, "#task-actions-error", "Only a tech lead can approve a task.") end)

    stub(Pipeline, :list_approvals, fn _task -> {:error, {:github_api_error, 502, %{}}} end)
    as_priya |> with_target("#task-actions") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#task-actions-error", "The approval did not finish. Try again.") end)

    {:ok, task} = Pipeline.update_task(task, %{pr_number: nil})
    as_priya |> with_target("#task-actions") |> render_click("approve", %{})

    eventually(fn ->
      assert has_element?(as_priya, "#task-actions-error", "This task has no pull request to approve.")
    end)

    {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 151})
    as_priya |> with_target("#task-actions") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#task-actions-error", "This task is at Review, not Finalize.") end)

    {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})
    as_priya |> with_target("#task-actions") |> render_click("approve", %{})
    eventually(fn -> assert has_element?(as_priya, "#task-actions-error", "This task is already merged.") end)
  end

  # A split's children share the header, so an answer for the child the lead switched away from is not this one's.
  test "an approval that lands after the lead switched children is dropped from the child on screen", %{
    conn: conn,
    project: project,
    priya: priya
  } do
    parent = learnings_task(project, "TAT-4", :split)
    %Task{id: first_id} = first = learnings_task(project, "TAT-5", :finalize)
    second = learnings_task(project, "TAT-6", :finalize)
    on_exit(fn -> Enum.each([parent, first, second], &File.rm_rf(&1.scratch_path)) end)

    for {child, position} <- [{first, 1}, {second, 2}] do
      child |> Ecto.Changeset.change(parent_task_id: parent.id, split_position: position) |> Repo.update!()
      {:ok, _ready} = Pipeline.update_task(child, %{pr_number: 150 + position, marked_ready_at: DateTime.utc_now()})
    end

    test_pid = self()

    expect(Pipeline, :approve_task, fn _scope, approved ->
      send(test_pid, {:approving, approved.id, self()})
      receive do: (:answer -> :ok)
      {:ok, [%{login: priya.login, user: priya, approved_at: ~U[2026-10-11 14:40:00Z]}]}
    end)

    assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{parent.id}?child=TAT-5")
    view |> element("#task-approve") |> render_click()
    assert_receive {:approving, ^first_id, approval}, 2_000
    assert has_element?(view, "#task-approve[disabled]")

    render_patch(view, ~p"/tasks/#{parent.id}?child=TAT-6")
    assert has_element?(view, "#task-approve:not([disabled])", "Approve")

    send(approval, :answer)
    render_async(view)

    refute has_element?(view, "#task-approved")
    refute has_element?(view, "#task-approvals")
    assert has_element?(view, "#task-approve:not([disabled])", "Approve")
  end

  # Approved in a tab, the approval reaches every other tab on the task by its broadcast.
  test "an approval from another tab is read again and shown", %{conn: conn, task: task, dan: dan, priya: priya} do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
    render_async(view)
    refute has_element?(view, "#task-approvals")

    stub(Pipeline, :list_approvals, fn _task ->
      {:ok, [%{login: priya.login, user: priya, approved_at: ~U[2026-10-11 14:40:00Z]}]}
    end)

    send(view.pid, {:approvals_changed, task.id})
    render_async(view)

    assert has_element?(view, "#task-approvals", "Approved by Priya Raman")
    refute has_element?(view, "#task-approved")
  end

  describe "a task past Plan whose plan no tech lead approved" do
    setup %{project: project, task: task} do
      {:ok, plan} = Roles.get_role(project_id: project.id, stage: :plan)

      Repo.insert!(%Round{
        task_id: task.id,
        number: 1,
        plan: "## Implementation plan",
        ticket: %Round.Ticket{title: "T", description: "D"}
      })

      {:ok, _run} =
        Pipeline.create_run(%{task_id: task.id, role_id: plan.id, status: :finished, started_at: DateTime.utc_now()})

      :ok
    end

    test "says so, and a tech lead approves the plan there, which the merge waited on", %{
      conn: conn,
      task: task,
      dan: dan,
      priya: priya
    } do
      {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)

      assert {:ok, as_dan, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
      assert has_element?(as_dan, "#task-plan-unapproved", "Plan not approved")
      refute has_element?(as_dan, "#task-approve-plan")

      assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")
      assert has_element?(view, "#task-plan-unapproved", "Plan not approved")
      assert has_element?(view, "#task-approve-plan", "Approve plan")

      view |> element("#task-merge") |> render_click()

      eventually(fn ->
        assert has_element?(view, "#task-actions-error", "A tech lead approves the plan before the task merges.")
      end)

      view |> element("#task-approve-plan") |> render_click()
      refute has_element?(view, "#task-actions-error")
      assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-plan-unapproved")
      refute has_element?(view, "#task-approve-plan")
      assert [%Round{approved_at: %DateTime{}}] = Pipeline.list_rounds(task)
    end

    test "once merged still says so, with nothing left to approve", %{conn: conn, task: task, priya: priya} do
      now = DateTime.utc_now()
      {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged, marked_ready_at: now, merged_at: now})

      assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-plan-unapproved")
      refute has_element?(view, "#task-approve-plan")
    end
  end

  describe "a branch the default branch has moved past" do
    setup %{task: task} do
      {:ok, task} = Pipeline.update_task(task, %{base_behind: true, base_conflicts: ["lib/a.ex", "lib/b.ex"]})
      %{task: task}
    end

    test "offers Update, counting the files that conflict, at Review and at Finalize", %{
      conn: conn,
      task: %Task{id: task_id} = task,
      dan: dan
    } do
      expect(Pipeline, :update_branch, fn _scope, %Task{id: ^task_id} -> {:ok, %Round{}} end)

      assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-conflicts", "Conflicts in 2 files with main")
      assert has_element?(view, "#task-update[title='Merge main in, as a round of its own']", "Update")

      view |> element("#task-update") |> render_click()
      refute has_element?(view, "#task-actions-error")

      {:ok, task} = Pipeline.update_task(task, %{stage: :review, base_conflicts: ["lib/a.ex"]})
      assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-conflicts", "Conflicts in 1 file with main")
      assert has_element?(view, "#task-update")

      {:ok, task} = Pipeline.update_task(task, %{base_conflicts: []})
      assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-conflicts")
      assert has_element?(view, "#task-update")
    end

    test "an Update the branch no longer needs says so", %{conn: conn, task: task, dan: dan} do
      expect(Pipeline, :update_branch, fn _scope, _task -> {:error, :up_to_date} end)

      assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
      view |> element("#task-update") |> render_click()

      assert has_element?(view, "#task-actions-error[role='alert']", "The branch is already up to date.")
    end
  end

  describe "the initial plan at Plan" do
    setup %{project: project, dan: dan} do
      task = learnings_task(project, "TAT-2", :plan)
      on_exit(fn -> File.rm_rf(task.scratch_path) end)
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

      Repo.insert!(%Round{
        task_id: task.id,
        number: 1,
        plan: "## Implementation plan",
        ticket: %Round.Ticket{title: "T", description: "D"}
      })

      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

      {:ok, issue} = Issues.update_issue(task.issue, %{owner_user_id: dan.id})

      %{plan_task: %{task | issue: issue}, plan_run: run}
    end

    test "its owner sends it to the tech leads, and is then told it is sent and can still start it", %{
      conn: conn,
      plan_task: task,
      dan: dan
    } do
      assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-send-plan", "Send plan to lead")
      assert has_element?(view, "#task-start-plan", "Start without approval")
      refute has_element?(view, "#task-approve-plan")
      refute has_element?(view, "#task-plan-sent")

      view |> element("#task-send-plan") |> render_click()
      assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-send-plan")
      assert has_element?(view, "#task-plan-sent", "Sent to the tech leads")
      assert has_element?(view, "#task-start-plan")
      refute has_element?(view, "#task-actions-error")
      assert [%Round{ready_at: %DateTime{}}] = Pipeline.list_rounds(task)
    end

    test "its owner starts it without approval", %{
      conn: conn,
      plan_task: task,
      plan_run: %{id: run_id} = run,
      dan: %{id: dan_id} = dan
    } do
      expect(Pipeline, :start_plan, fn %Scope{user: %{id: ^dan_id}}, %{id: ^run_id} -> {:ok, run} end)

      assert {:ok, view, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
      view |> element("#task-start-plan") |> render_click()

      refute has_element?(view, "#task-actions-error")
    end

    test "a tech lead who does not own it sees nothing until it is sent, then approves it", %{
      conn: conn,
      plan_task: task,
      plan_run: %{id: run_id} = run,
      dan: dan,
      michael: michael
    } do
      assert {:ok, view, _html} = live(log_in_user(conn, michael), ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-approve-plan")
      refute has_element?(view, "#task-send-plan")
      refute has_element?(view, "#task-start-plan")
      refute has_element?(view, "#task-plan-sent")

      {:ok, _sent} = Pipeline.send_plan_to_lead(Scope.for_user(dan), run)
      assert {:ok, view, _html} = live(log_in_user(conn, michael), ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-approve-plan", "Approve plan")
      refute has_element?(view, "#task-plan-sent")

      expect(Pipeline, :approve_plan, fn _scope, %{id: ^run_id} -> {:ok, run} end)
      view |> element("#task-approve-plan") |> render_click()

      refute has_element?(view, "#task-actions-error")
    end

    test "a tech lead who owns it approves it at once, and a refusal says why", %{
      conn: conn,
      plan_task: task,
      priya: priya
    } do
      {:ok, _owner} = Issues.update_issue(task.issue, %{owner_user_id: priya.id})
      expect(Pipeline, :approve_plan, fn _scope, _run -> {:error, :plan_not_ready} end)

      assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-approve-plan", "Approve plan")
      refute has_element?(view, "#task-send-plan")
      refute has_element?(view, "#task-start-plan")

      view |> element("#task-approve-plan") |> render_click()

      assert has_element?(
               view,
               "#task-actions-error[role='alert']",
               "The plan's owner has not sent it to the tech leads yet."
             )
    end

    test "every refusal of the plan says in a sentence what stopped it", %{
      conn: conn,
      plan_task: task,
      priya: priya
    } do
      assert {:ok, view, _html} = live(log_in_user(conn, priya), ~p"/tasks/#{task.id}")

      for {reason, sentence} <- [
            {:stage_running, "Something is still running on this task."},
            {:not_authorized, "Only a tech lead can approve a plan."},
            {:not_found, "This task is not in a project you can open."},
            {:already_approved, "The plan is already approved."},
            {:not_owner, "Only the task's owner sends or starts its plan."},
            {:no_pull_request, "This task has no pull request yet."},
            {:no_ticket, "Plan has not saved a ticket yet."},
            {:no_plan, "Plan has not saved a plan yet."},
            {:nothing_picked, "Pick a design before approving."},
            {:plan_not_for_pick, "The plan is not written for the picked design yet."},
            {:screenshot_missing, "The picked design has no screenshot yet."},
            {:stale_screenshot, "The screenshot is older than the design. Ask Plan to retake it."},
            {{:invalid_stage, :engineer}, "This task is at Implement."}
          ] do
        expect(Pipeline, :approve_plan, fn _scope, _run -> {:error, reason} end)
        view |> with_target("#task-actions") |> render_click("approve_plan", %{})

        assert has_element?(view, "#task-actions-error", sentence)
      end
    end

    test "nothing is offered while Plan works on it", %{
      conn: conn,
      plan_task: task,
      plan_run: run,
      dan: dan,
      michael: michael
    } do
      {:ok, _sent} = Pipeline.send_plan_to_lead(Scope.for_user(dan), run)
      {:ok, _working} = Pipeline.update_run(run, %{status: :running})

      assert {:ok, as_dan, _html} = live(log_in_user(conn, dan), ~p"/tasks/#{task.id}")
      refute has_element?(as_dan, "#task-send-plan")
      refute has_element?(as_dan, "#task-start-plan")

      assert {:ok, as_michael, _html} = live(log_in_user(conn, michael), ~p"/tasks/#{task.id}")
      refute has_element?(as_michael, "#task-approve-plan")
    end

    # Every page hands the header a task with its runs; one without them has no Plan run to act on.
    test "a task handed over without its runs still reads its plan", %{plan_task: task, dan: dan} do
      html = render_component(TaskActions, id: "task-actions", task: task, current_scope: Scope.for_user(dan))

      assert html =~ "task-send-plan"
      assert html =~ "task-start-plan"
    end
  end
end
