defmodule Rail.Pipeline.Actions.MergeTaskTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    Req.Test.stub(Rail.Linear, fn conn ->
      n = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_mt_#{n}", "identifier" => "MT-#{n}", "title" => "Merge Task #{n}"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Merge Task"})
    {:ok, task} = Pipeline.create_task(issue, :finalize)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 151, marked_ready_at: DateTime.utc_now()})

    {:ok, priya} = Users.register_oauth_user(%{github_id: "gh_mt_priya", login: "priya", email: "priya@example.com"})

    {:ok, priya} =
      Users.update_user(system_scope(), priya, %{
        name: "Priya Raman",
        tech_lead: true,
        project_ids: [project.id],
        github_token: "gho_priya"
      })

    %{task: task, lead: priya, scope: Scope.for_user(priya)}
  end

  test "a tech lead's merge says Merging, squash-merges as the lead, records it and enters Merged", %{
    task: %Task{id: task_id} = task,
    lead: %{id: lead_id},
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    test_pid = self()

    Req.Test.expect(Client, fn conn ->
      # GitHub is asked only once the claim is committed and every page heard it.
      send(test_pid, {:merging, Repo.reload!(task).merge_started_at})
      assert {"PUT", "/repos/example/test-seed/pulls/151/merge"} = {conn.method, conn.request_path}
      assert ["Bearer gho_priya"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"merged" => true, "sha" => "3c9a1f0e2b"})
    end)

    assert {:ok, %Task{stage: :merged, merged_by_id: ^lead_id, merge_sha: "3c9a1f0e2b", merged_at: %DateTime{}}} =
             Pipeline.merge_task(scope, task)

    assert_received {:merging, %DateTime{}}
    assert_received {:pipeline_changed, ^task_id}
    assert %Task{stage: :merged, merge_started_at: nil} = Repo.reload!(task)
    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: task.issue_id})
    refute_enqueued(worker: AdvanceSplit)
  end

  test "a lead with no GitHub token of their own merges as the app", %{project: project, task: task, lead: lead} do
    {:ok, tokenless} = Users.update_user(system_scope(), lead, %{github_token: nil})

    Req.Test.expect(Client, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"PUT", "/repos/example/test-seed/pulls/151/merge"} ->
          assert ["Bearer ghs_app"] = Plug.Conn.get_req_header(conn, "authorization")
          Req.Test.json(conn, %{"merged" => true, "sha" => "abc1234"})
      end
    end)

    assert {:ok, %Task{stage: :merged, merge_sha: "abc1234"}} = Pipeline.merge_task(Scope.for_user(tokenless), task)
    assert project.github_installation_id == 1
  end

  test "a lead whose token GitHub turns away merges as the app", %{task: task, scope: scope} do
    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, Plug.Conn.get_req_header(conn, "authorization")} do
        {"PUT", ["Bearer gho_priya"]} ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible"})

        {"POST", _app_jwt} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"PUT", ["Bearer ghs_app"]} ->
          Req.Test.json(conn, %{"merged" => true, "sha" => "def5678"})
      end
    end)

    assert {:ok, %Task{merge_sha: "def5678"}} = Pipeline.merge_task(scope, task)
  end

  test "a child's merge queues its parent's AdvanceSplit with the merge", %{project: project, scope: scope} do
    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Parent"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    {:ok, child_issue} = Issues.create_issue(system_scope(), project, %{title: "Child", parent: parent_issue})

    {:ok, child} =
      Pipeline.create_child_task(Repo.preload(parent, [:issue, :project]), child_issue, %{
        number: 1,
        builds_on: [],
        builds_screen: false,
        plan: "## Implementation plan\n\nPart 1."
      })

    {:ok, child} =
      Pipeline.update_task(child, %{stage: :finalize, pr_number: 151, marked_ready_at: DateTime.utc_now()})

    Req.Test.expect(Client, &Req.Test.json(&1, %{"merged" => true, "sha" => "c0ffee1"}))

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(scope, child)
    assert_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent.id})
  end

  test "a refusal keeps GitHub's message and leaves the task ready and unmerged", %{
    task: %Task{id: task_id} = task,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    Req.Test.expect(Client, fn conn ->
      conn
      |> Plug.Conn.put_status(405)
      |> Req.Test.json(%{"message" => ~s{Required status check "test (1.18, 27)" is failing.}})
    end)

    assert {:error, {:merge_refused, ~s{Required status check "test (1.18, 27)" is failing.}}} =
             Pipeline.merge_task(scope, task)

    assert %Task{
             stage: :finalize,
             merged_at: nil,
             merge_started_at: nil,
             merge_error: ~s{Required status check "test (1.18, 27)" is failing.},
             merge_error_at: %DateTime{}
           } = refused = Repo.reload!(task)

    assert Task.finalize_state(refused) == :refused
    assert_received {:pipeline_changed, ^task_id}
    assert_received {:pipeline_changed, ^task_id}

    # Merge stays there to try again, and a merge that goes clears the reason.
    Req.Test.expect(Client, &Req.Test.json(&1, %{"merged" => true, "sha" => "4b7d0e2"}))
    assert {:ok, %Task{stage: :merged, merge_error: nil}} = Pipeline.merge_task(scope, refused)
  end

  test "a refusal GitHub gives no message for, or that never reached GitHub, still says why", %{
    task: task,
    scope: scope
  } do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(409) |> Req.Test.json(%{})))
    assert {:error, {:merge_refused, "GitHub answered 409."}} = Pipeline.merge_task(scope, task)

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, {:merge_refused, "connection refused"}} = Pipeline.merge_task(scope, task)

    {:ok, tokenless} = Users.update_user(system_scope(), scope.user, %{github_token: nil})
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})))
    assert {:error, {:merge_refused, "Bad credentials"}} = Pipeline.merge_task(Scope.for_user(tokenless), task)
    assert %Task{stage: :finalize, merged_at: nil} = Repo.reload!(task)
  end

  test "a teammate without the setting is refused, admins included, and GitHub is never asked", %{
    project: project,
    task: task
  } do
    {:ok, admin} = Users.register_oauth_user(%{github_id: "gh_mt_admin", login: "admin", email: "a@example.com"})
    {:ok, admin} = Users.update_user(system_scope(), admin, %{admin: true})
    {:ok, dan} = Users.register_oauth_user(%{github_id: "gh_mt_dan", login: "dano", email: "d@example.com"})
    {:ok, dan} = Users.update_user(system_scope(), dan, %{project_ids: [project.id]})

    assert {:error, :not_authorized} = Pipeline.merge_task(Scope.for_user(admin), task)
    assert {:error, :not_authorized} = Pipeline.merge_task(Scope.for_user(dan), task)
    assert %Task{merge_started_at: nil, merged_at: nil} = Repo.reload!(task)
  end

  test "a tech lead without access to the project is refused", %{task: task, lead: lead} do
    assert {:error, :not_found} = Pipeline.merge_task(Scope.for_user(%{lead | project_ids: []}), task)
    assert %Task{merge_started_at: nil} = Repo.reload!(task)
  end

  test "a task not ready, already merging or already merged is refused", %{task: task, scope: scope} do
    {:ok, unmarked} = Pipeline.update_task(task, %{marked_ready_at: nil})
    assert {:error, :not_ready} = Pipeline.merge_task(scope, unmarked)

    {:ok, merging} =
      Pipeline.update_task(unmarked, %{marked_ready_at: DateTime.utc_now(), merge_started_at: DateTime.utc_now()})

    assert {:error, :merging} = Pipeline.merge_task(scope, merging)

    {:ok, merged} = Pipeline.update_task(merging, %{stage: :merged, merged_at: DateTime.utc_now()})
    assert {:error, :merged} = Pipeline.merge_task(scope, merged)

    {:ok, reviewing} = Pipeline.update_task(merged, %{stage: :review, merged_at: nil, merge_started_at: nil})
    assert {:error, {:invalid_stage, :review}} = Pipeline.merge_task(scope, reviewing)

    {:ok, no_pr} = Pipeline.update_task(reviewing, %{stage: :finalize, pr_number: nil})
    assert {:error, :no_pull_request} = Pipeline.merge_task(scope, no_pr)
  end

  # A merge whose caller died mid-call would otherwise hold the task for good.
  test "a claim older than a minute can be taken again", %{task: task, scope: scope} do
    {:ok, abandoned} = Pipeline.update_task(task, %{merge_started_at: DateTime.shift(DateTime.utc_now(), second: -61)})
    Req.Test.expect(Client, &Req.Test.json(&1, %{"merged" => true, "sha" => "9f3e2d1"}))

    assert {:ok, %Task{stage: :merged, merge_sha: "9f3e2d1"}} = Pipeline.merge_task(scope, abandoned)
  end
end
