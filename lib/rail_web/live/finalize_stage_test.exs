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
    priya = register.("priya", %{name: "Priya Raman", tech_lead: true, github_token: "gho_priya"})
    _michael = register.("mkerr", %{name: "Michael Kerr", tech_lead: true})

    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    task = learnings_task(project, "FST-1", :finalize)
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

    {:ok, _pass} = Pipeline.save_review(task)

    %{conn: conn, task: task, dan: dan, priya: priya}
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

    Req.Test.expect(Client, fn conn ->
      conn
      |> Plug.Conn.put_status(405)
      |> Req.Test.json(%{"message" => ~s{Required status check "test (1.18, 27)" is failing.}})
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
end
