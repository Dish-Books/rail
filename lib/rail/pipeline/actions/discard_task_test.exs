defmodule Rail.Pipeline.Actions.DiscardTaskTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  # A project of its own, because the branch is pushed to and deleted from a real `origin`.
  setup %{project: %{id: shared_project_id, linear_workspace_id: workspace_id}} do
    origin = Path.join(System.tmp_dir!(), "rail_discard_origin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(origin) end)
    git!(origin, ["init", "--bare", "--quiet", "-b", "main"])

    clone = create_temp_git_repo(prefix: "rail_discard_clone")
    git!(clone, ["remote", "add", "origin", origin])
    git!(clone, ["push", "--quiet", "origin", "main"])

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_discard"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Discard Project",
        github_repo: "org/discard",
        github_installation_id: 8707,
        key: "DSC",
        default_branch: "main",
        clone_path: clone,
        linear_workspace_id: workspace_id
      })

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_discard_1",
        identifier: "DSC-1",
        title: "Discard me",
        state: :in_review,
        state_name: "In Review",
        branch_name: "dsc-1-discard-me"
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, task} = Pipeline.create_task(issue, :review)
    git!(clone, ["worktree", "add", "--quiet", "-b", task.worktree_name, task.worktree_path])
    File.write!(Path.join(task.worktree_path, "work.ex"), "work\n")
    git!(task.worktree_path, ["add", "."])
    git!(task.worktree_path, ["commit", "--quiet", "-m", "Work"])
    git!(task.worktree_path, ["push", "--quiet", "origin", task.worktree_name])
    File.mkdir_p!(task.scratch_path)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, engineer} = Roles.get_role(project_id: shared_project_id, stage: :engineer)
    {:ok, lead} = Roles.get_role(project_id: shared_project_id, stage: :review_lead)
    test_pid = self()

    Req.Test.stub(Client, fn
      %{method: "POST", request_path: "/app/installations/8707/access_tokens"} = conn ->
        Req.Test.json(conn, %{"token" => "ghs_discard"})

      %{method: "GET", request_path: "/repos/org/discard/pulls/212"} = conn ->
        Req.Test.json(conn, %{"number" => 212, "state" => "open"})

      %{method: "PATCH", request_path: "/repos/org/discard/pulls/212"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:pull_request_changed, 212, Jason.decode!(body)})
        Req.Test.json(conn, %{"number" => 212, "state" => "closed"})
    end)

    {:ok, reader} =
      Users.register_oauth_user(%{github_id: "gh_discard", login: "discard-reader", email: "discard@example.com"})

    %{
      reader: reader,
      scope: user_scope(project_ids: [project.id]),
      issue: issue,
      task: task,
      origin: origin,
      engineer: engineer,
      lead: lead
    }
  end

  test "stops every run, closes the pull request, deletes the branch, files and task, and resets the ticket", %{
    scope: scope,
    task: task,
    issue: %Issue{id: issue_id} = issue,
    origin: origin,
    engineer: engineer,
    lead: lead,
    reader: reader
  } do
    {:ok, %Task{id: task_id} = task} = Pipeline.update_task(task, %{pr_number: 212})
    now = DateTime.utc_now()

    runs =
      for {role, status, error} <- [
            {lead, :running, nil},
            {engineer, :waiting_for_resources, nil},
            {engineer, :blocked_on_input, nil},
            {engineer, :failed, "It crashed."}
          ] do
        {:ok, run} = Pipeline.create_run(%{task_id: task_id, role_id: role.id, status: status, started_at: now})
        if error, do: {:ok, _failed} = Pipeline.update_run(run, %{error: error})
        run
      end

    [%Run{id: running_id}, _waiting, %Run{} = parked, %Run{id: failed_id}] = runs
    run_ids = Enum.map(runs, & &1.id)
    {:ok, %{asked: [%Question{id: question_id}]}} = Pipeline.ask_questions(parked, [%{"prompt" => "Which way?"}])
    Pipeline.append_run_events(failed_id, nil, ["It crashed."])

    %OsProcess{id: os_process_id} =
      Repo.insert!(%OsProcess{
        run_id: failed_id,
        task_id: task_id,
        stream_path: "/dev/null",
        status: :finished,
        started_at: now,
        reserved_cpus: 1,
        launch: Jason.encode!(%{"executable" => "/bin/true", "args" => [], "env" => %{}, "cwd" => "/tmp"})
      })

    Repo.insert!(%Round{task_id: task_id, number: 2, plan: "Guard nil."})

    %Finding{id: finding_id} =
      Repo.insert!(%Finding{
        task_id: task_id,
        key: "a-nit",
        kind: :code,
        raised_by: :code_reviewer,
        round: 1,
        title: "A nit",
        severity: :nit,
        recommendation: :skip
      })

    %DiffComment{id: comment_id} =
      Repo.insert!(%DiffComment{
        task_id: task_id,
        user_id: reader.id,
        path: "work.ex",
        line_kind: :added,
        filter: :branch,
        line: 1,
        body: "Why?"
      })

    %Learning{id: rule_id} = rule = learning(issue.project, %{rule: "Don't flag a nit", kind: :calibration})
    finding = %Finding{id: "fnd_discard_1", title: "A nit", suppressed_by_id: rule.id}
    {:ok, [%Observation{id: observation_id}]} = Learnings.record_overrides(%{task | issue: issue}, [finding])

    assert {:ok, %Task{id: ^task_id}} = Pipeline.discard_task(scope, task)

    assert_receive {:pull_request_changed, 212, %{"state" => "closed"}}
    assert Repo.get(Task, task_id) == nil
    assert Repo.all(from(r in Run, where: r.id in ^run_ids or r.task_id == ^task_id)) == []
    assert Repo.get(Run, running_id) == nil
    assert Repo.get(OsProcess, os_process_id) == nil
    assert Repo.all(from(e in RunEvent, where: e.run_id == ^failed_id)) == []
    assert Repo.get(Question, question_id) == nil
    assert Repo.all(from(r in Round, where: r.task_id == ^task_id)) == []
    assert Repo.get(Finding, finding_id) == nil
    assert Repo.get(DiffComment, comment_id) == nil
    assert Repo.get(Observation, observation_id) == nil
    assert %Learning{id: ^rule_id} = Repo.get(Learning, rule_id)
    assert "" = git!(origin, ["branch", "--list", task.worktree_name])
    refute File.exists?(task.worktree_path)
    refute File.exists?(task.scratch_path)
    assert %Issue{state: :todo, state_name: nil} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
  end

  test "a pull request opened while Discard waited on the task's lock is closed too", %{scope: scope, task: task} do
    pending =
      with_task_lock(task.id, fn ->
        pending = Elixir.Task.async(fn -> Pipeline.discard_task(scope, task) end)
        refute Elixir.Task.yield(pending, 100)
        {:ok, _opened} = Pipeline.update_task(task, %{pr_number: 212})
        pending
      end)

    assert {:ok, %Task{}} = Elixir.Task.await(pending)
    assert_receive {:pull_request_changed, 212, %{"state" => "closed"}}
  end

  test "a new task for the issue pushes onto the same branch name cleanly", %{scope: scope, task: task, issue: issue} do
    assert {:ok, %Task{}} = Pipeline.discard_task(scope, task)

    {:ok, %Task{id: new_id} = new_task} = Pipeline.create_task(issue, :plan)
    assert new_id != task.id
    assert new_task.worktree_name == task.worktree_name
    git!(issue.project.clone_path, ["worktree", "add", "--quiet", "-b", new_task.worktree_name, new_task.worktree_path])
    File.write!(Path.join(new_task.worktree_path, "fresh.ex"), "fresh\n")
    git!(new_task.worktree_path, ["add", "."])
    git!(new_task.worktree_path, ["commit", "--quiet", "-m", "Fresh start"])

    assert :ok = Git.check_push(new_task)
  end

  test "a task whose branch was never pushed is discarded", %{scope: scope, task: task, origin: origin} do
    git!(origin, ["branch", "-D", task.worktree_name])

    assert {:ok, %Task{}} = Pipeline.discard_task(scope, task)
    assert Repo.get(Task, task.id) == nil
  end

  test "a process still live after the stops leaves everything as it was", %{scope: scope, task: task, origin: origin} do
    stub(Tools, :list_os_processes, fn [task_id: _id, status: _live] -> [%OsProcess{status: :starting}] end)

    assert {:error, :task_busy} = Pipeline.discard_task(scope, task)
    assert git!(origin, ["branch", "--list", task.worktree_name]) =~ task.worktree_name
    assert %Task{cleaned_up_at: nil} = Repo.reload!(task)
  end

  test "a run still working when the lock is taken leaves everything as it was", %{
    scope: scope,
    task: task,
    engineer: engineer,
    origin: origin
  } do
    pending =
      with_task_lock(task.id, fn ->
        pending = Elixir.Task.async(fn -> Pipeline.discard_task(scope, task) end)
        refute Elixir.Task.yield(pending, 100)

        {:ok, run} =
          Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :running, started_at: DateTime.utc_now()})

        {pending, run}
      end)

    {pending, %Run{id: run_id}} = pending
    assert {:error, :task_busy} = Elixir.Task.await(pending)
    assert %Run{status: :running} = Repo.get!(Run, run_id)
    assert git!(origin, ["branch", "--list", task.worktree_name]) =~ task.worktree_name
  end

  test "a remote that refuses the delete leaves the worktree, the task and the ticket as they were", %{
    scope: scope,
    task: task,
    issue: %Issue{id: issue_id},
    origin: origin,
    engineer: engineer
  } do
    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :failed, started_at: DateTime.utc_now()})

    hook = Path.join([origin, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'Repository rule violations found' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    assert {:error, {:branch_not_deleted, output}} = Pipeline.discard_task(scope, task)
    assert output =~ "Repository rule violations found"
    assert File.exists?(task.worktree_path)
    assert %Task{cleaned_up_at: nil} = Repo.reload!(task)
    assert %Issue{state: :in_review, state_name: "In Review"} = Repo.get!(Issue, issue_id)
    assert %Run{} = Repo.get(Run, run_id)
    refute_enqueued(worker: SyncIssue)
  end

  test "GitHub refusing to close the pull request changes nothing local", %{scope: scope, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 213})

    Req.Test.stub(Client, fn
      %{method: "POST"} = conn -> Req.Test.json(conn, %{"token" => "ghs_discard"})
      conn -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible"})
    end)

    assert {:error, {:pull_request_not_closed, {:github_api_error, 403, _body}}} =
             Pipeline.discard_task(scope, task)

    assert File.exists?(task.worktree_path)
    assert %Task{cleaned_up_at: nil} = Repo.reload!(task)
  end

  test "a pull request already merged or closed is left as it is", %{scope: scope, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 214})

    Req.Test.stub(Client, fn
      %{method: "POST"} = conn -> Req.Test.json(conn, %{"token" => "ghs_discard"})
      %{method: "GET"} = conn -> Req.Test.json(conn, %{"number" => 214, "state" => "closed"})
    end)

    assert {:ok, %Task{}} = Pipeline.discard_task(scope, task)
    assert Repo.get(Task, task.id) == nil
  end

  test "a finished ticket keeps its status, nothing is sent to the tracker and its page is told", %{
    scope: scope,
    task: task,
    issue: issue
  } do
    %Issue{id: issue_id} = issue |> Ecto.Changeset.change(state: :canceled, state_name: "Canceled") |> Repo.update!()
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Task{}} = Pipeline.discard_task(scope, task)
    assert Repo.get(Task, task.id) == nil
    assert %Issue{state: :canceled, state_name: "Canceled"} = Repo.get!(Issue, issue_id)
    assert_receive {:issue_changed, ^issue_id}
    refute_enqueued(worker: SyncIssue)
  end

  test "an issue linked to an adopted pull request lets the link go once it is closed", %{
    scope: scope,
    task: task,
    issue: issue
  } do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 212})

    %Issue{id: issue_id} =
      issue
      |> Issue.pull_request_changeset(%{pr_number: 212, pr_url: "https://github.com/org/discard/pull/212"})
      |> Repo.update!()

    Req.Test.stub(Client, fn
      %{method: "POST"} = conn ->
        Req.Test.json(conn, %{"token" => "ghs_discard"})

      %{method: "GET", request_path: "/repos/org/discard/pulls"} = conn ->
        Req.Test.json(conn, [])

      %{method: "GET", request_path: "/repos/org/discard/pulls/212"} = conn ->
        state = if Process.get(:closed), do: "closed", else: "open"
        Req.Test.json(conn, %{"number" => 212, "state" => state})

      %{method: "PATCH"} = conn ->
        Process.put(:closed, true)
        Req.Test.json(conn, %{"number" => 212, "state" => "closed"})
    end)

    assert {:ok, %Task{}} = Pipeline.discard_task(scope, task)
    assert Repo.get(Task, task.id) == nil
    assert %Issue{pr_number: nil, pr_url: nil} = Repo.get!(Issue, issue_id)
  end

  describe "a task it refuses" do
    test "a second discard, after a new task has started for the issue, changes nothing", %{
      scope: scope,
      task: task,
      issue: issue
    } do
      {:ok, %Task{}} = Pipeline.discard_task(scope, task)
      {:ok, %Task{id: new_id}} = Pipeline.create_task(issue, :plan)
      %Issue{id: issue_id} = issue |> Ecto.Changeset.change(state: :in_progress) |> Repo.update!()

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, task)
      assert %Task{cleaned_up_at: nil, stage: :plan} = Repo.get!(Task, new_id)
      assert %Issue{state: :in_progress} = Repo.get!(Issue, issue_id)
    end

    test "a cleaned-up task keeps its runs as history", %{scope: scope, task: task, engineer: engineer} do
      {:ok, %Run{id: run_id}} =
        Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :finished, started_at: DateTime.utc_now()})

      {:ok, cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, cleaned)
      assert %Run{} = Repo.get(Run, run_id)
      assert %Task{} = Repo.get(Task, task.id)
    end

    test "a task merged but still at Finalize keeps its branch", %{scope: scope, task: task, origin: origin} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :finalize, merged_at: DateTime.utc_now()})

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, task)
      assert git!(origin, ["branch", "--list", task.worktree_name]) =~ task.worktree_name
      assert %Task{} = Repo.get(Task, task.id)
    end

    test "a task whose merge is in progress says so and changes nothing", %{scope: scope, task: task, lead: lead} do
      now = DateTime.utc_now()

      {:ok, task} =
        Pipeline.update_task(task, %{stage: :finalize, marked_ready_at: now, merge_started_at: now, pr_number: 212})

      {:ok, %Run{id: run_id}} =
        Pipeline.create_run(%{task_id: task.id, role_id: lead.id, status: :running, started_at: now})

      assert {:error, :merging} = Pipeline.discard_task(scope, task)
      assert %Task{} = Repo.get(Task, task.id)
      assert %Run{status: :running} = Repo.get!(Run, run_id)
      refute_received {:pull_request_changed, _number, _body}
    end

    test "a split parent", %{scope: scope, task: task} do
      {:ok, parent} = Pipeline.update_task(task, %{stage: :split})

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, parent)
      assert %Task{} = Repo.get(Task, parent.id)
    end

    test "a child of a split", %{scope: scope, task: task, issue: issue} do
      parent_issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: issue.project_id,
          external_id: "lin_discard_parent",
          identifier: "DSC-2",
          title: "Split",
          state: :in_progress
        })
        |> Repo.insert!()
        |> Repo.preload(:project)

      {:ok, %Task{id: parent_id}} = Pipeline.create_task(parent_issue, :split)
      child = task |> Ecto.Changeset.change(parent_task_id: parent_id) |> Repo.update!()

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, child)
      assert %Task{} = Repo.get(Task, child.id)
    end

    test "a scope that cannot open the project", %{task: task} do
      assert {:error, :not_found} = Pipeline.discard_task(user_scope(), task)
      assert %Task{} = Repo.get(Task, task.id)
    end
  end
end
