defmodule Rail.Pipeline.Actions.RequestCoderabbitReviewTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.TimeOutCoderabbitReview
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    scratch = Path.join(System.tmp_dir!(), "coderabbit_request_#{System.unique_integer([:positive])}")
    worktree = Path.join(scratch, "worktree")
    Enum.each([worktree, worktree <> ".git"], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(scratch) end)
    head = String.duplicate("c", 40)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: head, dirty_digest: "clean"} end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "CodeRabbit request"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    {:ok, task} =
      Pipeline.update_task(task, %{pr_number: 151, worktree_path: worktree, scratch_path: Path.join(scratch, "scratch")})

    {:ok, _round} = Pipeline.create_round(task)

    {:ok, dev} =
      Users.register_oauth_user(%{github_id: "gh_crr_dev", login: "dev-crr", email: "dev-crr@example.com"})

    {:ok, dev} =
      Users.update_user(system_scope(), dev, %{
        name: "Dana Dev",
        project_ids: [project.id],
        github_token: "gho_dana",
        github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
      })

    %{task: task, dev: dev, scope: Scope.for_user(dev), head: head}
  end

  test "asks for a full review from the asker's own account and counts it on the task", %{
    task: %Task{id: task_id} = task,
    dev: %User{id: dev_id},
    scope: scope,
    head: head
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    Req.Test.expect(Client, fn conn ->
      assert {"POST", "/repos/example/test-seed/issues/151/comments"} = {conn.method, conn.request_path}
      assert ["Bearer gho_dana"] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"body" => "@coderabbitai full review"} = Jason.decode!(body)
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 7001})
    end)

    assert {:ok, %CoderabbitReview{id: review_id, status: :requested, command: :full, external_id: 7001}} =
             Pipeline.request_coderabbit_review(scope, task)

    assert [
             %CoderabbitReview{
               id: ^review_id,
               round: 1,
               pr_number: 151,
               head_sha: ^head,
               requested_by: %User{id: ^dev_id}
             }
           ] = Pipeline.list_coderabbit_reviews(task)

    assert_enqueued(worker: TimeOutCoderabbitReview, args: %{review_id: review_id})
    assert_receive {:pipeline_changed, ^task_id}
  end

  test "after a review CodeRabbit finished, the next asks only for the commits since", %{task: task, scope: scope} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})))

    {:ok, first} = Pipeline.request_coderabbit_review(scope, task)
    {:ok, _done} = first |> CoderabbitReview.status_changeset(:done) |> Repo.update()

    Req.Test.expect(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"body" => "@coderabbitai review"} = Jason.decode!(body)
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 2})
    end)

    assert {:ok, %CoderabbitReview{command: :incremental}} = Pipeline.request_coderabbit_review(scope, task)
  end

  test "a review still waiting holds a second ask, and nothing reaches GitHub", %{task: task, scope: scope} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})))
    {:ok, _waiting} = Pipeline.request_coderabbit_review(scope, task)

    assert {:error, :coderabbit_pending} = Pipeline.request_coderabbit_review(scope, task)
  end

  test "asked at Finalize, the task goes back to Review, unmarked, with its last pass open again", %{
    task: task,
    scope: scope,
    head: head
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    {:ok, %{round: 1}} = Pipeline.save_review(Repo.preload(task, :issue))

    {:ok, task} =
      Pipeline.update_task(task, %{stage: :finalize, marked_ready_at: DateTime.utc_now()})

    reviews_file = Path.join([task.scratch_path, "reviews", "#{Repo.preload(task, :issue).issue.identifier}.json"])
    passes = reviews_file |> File.read!() |> Jason.decode!()
    finished = put_in(passes, ["passes", Access.at(0), "finished_at"], DateTime.to_iso8601(DateTime.utc_now()))
    File.write!(reviews_file, Jason.encode!(finished))

    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})))

    assert {:ok, %CoderabbitReview{}} = Pipeline.request_coderabbit_review(scope, task)
    assert %Task{stage: :review, marked_ready_at: nil} = task = Repo.reload!(task)
    assert [%{round: 1, head: ^head, finished_at: nil}] = Pipeline.read_review(Repo.preload(task, :issue))
  end

  test "GitHub's refusal is said and nothing is counted", %{task: task, scope: scope} do
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Forbidden"})))

    assert {:error, {:github_api_error, 403, %{"message" => "Forbidden"}}} =
             Pipeline.request_coderabbit_review(scope, task)

    assert [] = Pipeline.list_coderabbit_reviews(task)
  end

  test "a task a review cannot be asked on now is refused before GitHub is reached", %{task: task, scope: scope} do
    {:ok, at_engineer} = Pipeline.update_task(task, %{stage: :engineer})
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.request_coderabbit_review(scope, at_engineer)

    {:ok, no_pr} = Pipeline.update_task(at_engineer, %{stage: :review, pr_number: nil})
    assert {:error, :no_pull_request} = Pipeline.request_coderabbit_review(scope, no_pr)

    {:ok, merged} = Pipeline.update_task(no_pr, %{pr_number: 151, merged_at: DateTime.utc_now()})
    assert {:error, :merged} = Pipeline.request_coderabbit_review(scope, merged)

    {:ok, merging} =
      Pipeline.update_task(merged, %{
        stage: :finalize,
        merged_at: nil,
        marked_ready_at: DateTime.utc_now(),
        merge_started_at: DateTime.utc_now()
      })

    assert {:error, :merging} = Pipeline.request_coderabbit_review(scope, merging)

    {:ok, cleaned} = Pipeline.update_task(merging, %{cleaned_up_at: DateTime.utc_now()})
    assert {:error, :cleaned_up} = Pipeline.request_coderabbit_review(scope, cleaned)
  end

  test "a task whose checkout is gone has no commit to review", %{task: task, scope: scope} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/nonexistent/coderabbit"})
    assert {:error, :no_worktree} = Pipeline.request_coderabbit_review(scope, task)
  end

  test "an asker with no GitHub token, no user, or outside the project is refused", %{task: task, project: project} do
    {:ok, tokenless} =
      Users.register_oauth_user(%{github_id: "gh_crr_none", login: "none-crr", email: "none-crr@example.com"})

    {:ok, tokenless} = Users.update_user(system_scope(), tokenless, %{project_ids: [project.id]})

    assert {:error, :no_github_token} = Pipeline.request_coderabbit_review(Scope.for_user(tokenless), task)
    assert {:error, :no_github_token} = Pipeline.request_coderabbit_review(system_scope(), task)

    {:ok, outsider} = Users.update_user(system_scope(), tokenless, %{project_ids: []})
    assert {:error, :not_found} = Pipeline.request_coderabbit_review(Scope.for_user(outsider), task)

    assert {:error, :not_found} =
             Pipeline.request_coderabbit_review(Scope.for_user(outsider), %{task | id: "tsk_missing"})
  end
end
