defmodule Rail.Pipeline.Utils.ReviewRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Users

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

    # Review takes a branch the engineer's hand-over pushed, so a turn sends on only what it committed.
    stub(Git, :branch_unpushed?, fn _path -> false end)

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
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :finalize, pr_is_draft: false} = Repo.reload!(task)
    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
    assert_received {:pipeline_changed, _changed}
  end

  # A comment resumes the lead at Finalize and after the merge, and its turn ends here again.
  test "a turn resumed by a comment at Finalize or after the merge leaves the stage where it is", %{
    task: task,
    run: run
  } do
    {:ok, _closed} = Pipeline.save_review(task)
    {:ok, finalizing} = Pipeline.update_task(task, %{stage: :finalize, pr_is_draft: false})

    assert %Run{error: nil} = review_run_finished(%{run | task: finalizing}, [])
    assert %Task{stage: :finalize} = Repo.reload!(task)

    {:ok, merged} = Pipeline.update_task(finalizing, %{stage: :merged, merged_at: DateTime.utc_now()})

    assert %Run{error: nil} = review_run_finished(%{run | task: merged}, [])
    assert %Task{stage: :merged} = Repo.reload!(task)
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

  # Send or Finish review is theirs, so nobody's comments are left behind a review that finished itself.
  test "anyone's unsent diff or screen comment holds the review open, and it finishes once there are none", %{
    task: task,
    run: run
  } do
    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_rfn_ada",
        login: "ada-review-run-finished",
        email: "ada-review-run-finished@example.com"
      })

    ada = user_scope(user: ada)
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", "toolbar"]))
    File.write!(Path.join([task.scratch_path, "qa", "screens", "toolbar", "1.jpg"]), "jpeg")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})
    {:ok, _closed} = Pipeline.save_review(task)

    {:ok, diff} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 1,
        line_text: "x",
        filter: :branch,
        body: "Name it."
      })

    {:ok, screen} = Pipeline.create_screen_comment(ada, task, %{"key" => "toolbar", "body" => "Fold it."})

    assert %Run{error: nil} = review_run_finished(run, [])
    {:ok, _removed} = Pipeline.delete_diff_comment(ada, diff)
    assert %Run{error: nil} = review_run_finished(run, [])
    assert [%{finished_at: nil}] = Pipeline.read_review(task)

    {:ok, _removed} = Pipeline.delete_screen_comment(ada, screen)
    {:ok, task} = Pipeline.update_task(task, %{pr_is_draft: false})

    assert %Run{error: nil} = review_run_finished(%{run | task: task}, [])
    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
  end

  test "anyone's unsent finding comment holds the review open, also on a finding ruled Don't fix", %{
    task: task,
    run: run,
    finding: finding
  } do
    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_rfn_fc", login: "ada_fc", email: "ada_fc@example.com"})
    ada = user_scope(user: ada)
    {:ok, saved} = Pipeline.save_finding(task, finding)
    {:ok, _closed} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), saved, :skip)

    {:ok, comment} =
      Pipeline.create_finding_comment(ada, task, %{"finding_id" => saved.id, "piece" => "title", "body" => "Fix it."})

    assert %Run{error: nil} = review_run_finished(run, [])
    assert [%{finished_at: nil}] = Pipeline.read_review(task)

    {:ok, _removed} = Pipeline.delete_finding_comment(ada, comment)
    {:ok, task} = Pipeline.update_task(task, %{pr_is_draft: false})

    assert %Run{error: nil} = review_run_finished(%{run | task: task}, [])
    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
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

  describe "a turn that committed" do
    setup %{task: task, worktree: worktree} do
      {:ok, _closed} = Pipeline.save_review(task)
      git!(worktree, ["commit", "--allow-empty", "-m", "Guard the nil"])
      stub(Git, :branch_unpushed?, fn _path -> true end)
      :ok
    end

    test "with a Fix finding not saved fixed is held, and nothing is sent on", %{task: task, run: run, finding: finding} do
      {:ok, saved} = Pipeline.save_finding(task, finding)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), saved, :fix)
      reject(&Pipeline.hand_over_work/2)

      assert %Run{error: "This turn committed, but unhandled-nil ruled Fix is not saved as fixed." <> _rest} =
               review_run_finished(run, [])
    end

    test "with two Fix findings not saved fixed names both", %{task: task, run: run, finding: finding} do
      for key <- ["unhandled-nil", "unhandled-empty"] do
        {:ok, saved} = Pipeline.save_finding(task, %{finding | key: key})
        {:ok, _ruled} = Pipeline.decide_finding(system_scope(), saved, :fix)
      end

      reject(&Pipeline.hand_over_work/2)

      assert %Run{error: "This turn committed, but " <> named} = review_run_finished(run, [])
      assert named =~ ~r/unhandled-(nil|empty), unhandled-(nil|empty) ruled Fix are not saved as fixed/
    end

    # Bringing the branch up to date before the human has ruled owes no fix report yet.
    test "while findings wait on the human hands the commits over", %{task: task, run: run, finding: finding} do
      {:ok, _saved} = Pipeline.save_finding(task, finding)
      expect(Pipeline, :hand_over_work, fn _scope, %Run{} = run -> {:ok, %{run | status: :running}} end)

      assert %Run{status: :running, error: nil} = review_run_finished(run, [])
    end

    test "that only pushed has the round it closed checked as any other", %{task: task, run: run} do
      {:ok, _read} = Pipeline.save_review(task)
      expect(Pipeline, :hand_over_work, fn _scope, %Run{} = run -> {:ok, run} end)

      assert %Run{error: nil} = review_run_finished(%{run | pending_chat: "One more thing"}, [])
    end

    test "whose branch someone pushed to outside Rail goes back to the lead", %{run: %Run{id: run_id} = run} do
      expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, :pushed_outside_rail} end)

      expect(Rail.Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "Have the engineer merge"
        {:ok, %Rail.Tools.Schemas.OsProcess{run: spawned}}
      end)

      assert %Run{id: ^run_id, error: nil} = review_run_finished(run, [])
    end

    test "whose commits could not be sent on says why", %{run: run} do
      expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, "remote rejected"} end)

      assert %Run{error: "The Review lead's commits could not be sent on: remote rejected"} =
               review_run_finished(run, [])
    end

    test "whose hand-over was refused says why", %{run: run} do
      expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, {:invalid_stage, :engineer}} end)

      assert %Run{error: "The Review lead's commits could not be sent on: {:invalid_stage, :engineer}"} =
               review_run_finished(run, [])
    end
  end

  describe "a turn on a fix round's plan" do
    setup %{task: task, worktree: worktree} do
      {:ok, _closed} = Pipeline.save_review(task)
      path = Path.join([task.scratch_path, "fix_plans", "RFN-1.json"])
      File.mkdir_p!(Path.dirname(path))
      head = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()
      # As a Send of one comment leaves it.
      File.write!(
        path,
        Jason.encode!(%{round: 1, head: head, findings: [], comments: [%{number: 1, kind: "diff", text: "Why?"}]})
      )

      %{path: path}
    end

    test "that saved the plan ends done with the review open, even with nothing left to rule, and sends nothing on", %{
      task: task,
      run: run
    } do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => "### What changes\n\n#### Comment 1\n\nAnswered."})
      reject(&Pipeline.hand_over_work/2)

      assert %Run{error: nil} = review_run_finished(run, [])
      assert %Task{stage: :review, pr_is_draft: true} = Repo.reload!(task)
      assert [%{finished_at: nil}] = Pipeline.read_review(task)
    end

    test "that ended with no plan saved records that, with nothing to approve", %{run: run} do
      assert %Run{error: "The Review lead did not save a fix plan."} = review_run_finished(run, [])
    end

    test "that committed before approval is held and sends nothing on", %{task: task, run: run, worktree: worktree} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => "### What changes\n\n#### Comment 1\n\nAnswered."})
      git!(worktree, ["commit", "--allow-empty", "-m", "Too soon"])
      stub(Git, :branch_unpushed?, fn _path -> true end)
      reject(&Pipeline.hand_over_work/2)

      assert %Run{error: "This turn committed while the fix plan waits on approval." <> _rest} =
               review_run_finished(run, [])
    end

    # A fix commit CI failed is still unpushed when the next Send asks for a plan, and is no commit of this turn's.
    test "on a branch already unpushed when the round was sent ends done with the plan saved", %{task: task, run: run} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => "### What changes\n\n#### Comment 1\n\nAnswered."})
      stub(Git, :branch_unpushed?, fn _path -> true end)
      reject(&Pipeline.hand_over_work/2)

      assert %Run{error: nil} = review_run_finished(run, [])
    end

    test "after approval hands its commits over as any fix round does", %{task: task, run: run, path: path} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => "### What changes\n\n#### Comment 1\n\nAnswered."})
      approved = path |> File.read!() |> Jason.decode!() |> Map.put("approved_at", "2026-10-12T16:58:00Z")
      File.write!(path, Jason.encode!(approved))
      stub(Git, :branch_unpushed?, fn _path -> true end)
      expect(Pipeline, :hand_over_work, fn _scope, %Run{} = run -> {:ok, %{run | status: :running}} end)

      assert %Run{status: :running, error: nil} = review_run_finished(run, [])
    end
  end
end
