defmodule Rail.Pipeline.Utils.ReviewRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rfn_1", "identifier" => "RFN-1", "title" => "Review Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Review Finished"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    worktree = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree, pr_number: 42, pr_is_draft: true})
    task = Repo.preload(task, :issue)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        # What `run_finished/3` hands over: the process has exited and the run is settled.
        status: :finished,
        conversation_id: "sess_review_finished",
        started_at: DateTime.utc_now()
      })

    %{
      task: task,
      worktree: worktree,
      run: Repo.preload(run, [:task, :role]),
      finding: %{
        key: "unhandled-nil",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Nil is not handled",
        problem: "It crashes.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard it.",
        why: "It crashes.",
        rule: "Every caller handles nil.",
        severity: :major,
        recommendation: :fix,
        places: [%{file: "lib/a.ex", line: 3}],
        evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
      }
    }
  end

  test "a round with a finding to rule waits for the human, with the pull request in draft", %{
    task: task,
    run: run,
    finding: finding
  } do
    {:ok, _saved} = Pipeline.save_finding(task, finding)
    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :review, pr_is_draft: true} = Repo.reload!(task)
    assert [%{finished_at: nil}] = Pipeline.read_review(task)
  end

  test "a round that leaves nothing to rule or fix finishes the review and takes the pull request out of draft", %{
    task: task,
    run: run
  } do
    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/42"} ->
          Req.Test.json(conn, %{"number" => 42, "node_id" => "PR_42"})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{"pullRequest" => %{"isDraft" => false}}}})
      end
    end)

    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :review, pr_is_draft: false} = Repo.reload!(task)
    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
  end

  test "a review already finished is not finished again", %{task: task, run: run} do
    {:ok, _closed} = Pipeline.save_review(task)
    {:ok, task} = Pipeline.update_task(task, %{pr_is_draft: false})
    %Run{} = review_run_finished(%{run | task: task}, [])
    [%{finished_at: finished_at}] = Pipeline.read_review(task)

    assert %Run{error: nil} = review_run_finished(%{run | task: task}, [])
    assert [%{finished_at: ^finished_at}] = Pipeline.read_review(task)
  end

  test "a message the human queued holds the review open", %{task: task, run: run} do
    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil} = review_run_finished(%{run | pending_chat: "One more thing"}, [])
    assert [%{finished_at: nil}] = Pipeline.read_review(task)
  end

  test "a turn that ends without saving its review records that, and moves nothing", %{task: task, run: run} do
    assert %Run{error: "The Review lead did not save its review."} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a turn after a fix round's commit owes a round, so the last pass does not stand for it", %{
    task: task,
    run: run,
    worktree: worktree
  } do
    {:ok, _closed} = Pipeline.save_review(task)
    File.write!(Path.join(worktree, "fixed.ex"), "fixed\n")
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "Fix round 1"])

    assert %Run{error: "The Review lead did not save its review."} = review_run_finished(run, [])
  end

  test "a pass with no commit is taken at its word", %{task: task, run: run, finding: finding} do
    {:ok, %{head: nil}} = Pipeline.save_review(%{task | worktree_path: "/nonexistent/rfn"})
    {:ok, _ruled_later} = Pipeline.save_finding(task, finding)

    assert %Run{error: nil} = review_run_finished(run, [])
  end
end
