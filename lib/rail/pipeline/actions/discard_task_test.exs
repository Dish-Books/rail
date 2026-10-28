defmodule Rail.Pipeline.Actions.DiscardTaskTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

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

    %{
      scope: user_scope(project_ids: [project.id]),
      issue: issue,
      task: task,
      origin: origin,
      engineer: engineer,
      lead: lead
    }
  end

  test "stops every run, closes questions and the pull request, deletes the branch and files, and resets the ticket",
       %{scope: scope, task: task, issue: %Issue{id: issue_id}, origin: origin, engineer: engineer, lead: lead} do
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

    [_running, _waiting, %Run{id: parked_id} = parked, _failed] = runs
    {:ok, %{asked: [%Question{id: question_id}]}} = Pipeline.ask_questions(parked, [%{"prompt" => "Which way?"}])

    assert {:ok, %Task{id: ^task_id, cleaned_up_at: %DateTime{}}} = Pipeline.discard_task(scope, task)

    assert_receive {:pull_request_changed, 212, %{"state" => "closed"}}

    for run <- Repo.all(from(r in Run, where: r.task_id == ^task_id, preload: :questions)),
        do: assert(Run.state(run) in [:stopped, :failed])

    assert %Run{id: ^parked_id, status: :finished} = Repo.get!(Run, parked_id)
    assert %Question{status: :dismissed, delivered_at: %DateTime{}} = Repo.get!(Question, question_id)
    assert "" = git!(origin, ["branch", "--list", task.worktree_name])
    refute File.exists?(task.worktree_path)
    refute File.exists?(task.scratch_path)
    assert %Issue{state: :todo, state_name: nil} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
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

    assert {:ok, %Task{cleaned_up_at: %DateTime{}}} = Pipeline.discard_task(scope, task)
  end

  test "a process still live after the stops leaves everything as it was", %{scope: scope, task: task, origin: origin} do
    stub(Tools, :list_os_processes, fn [task_id: _id, status: _live] -> [%OsProcess{status: :starting}] end)

    assert {:error, :task_busy} = Pipeline.discard_task(scope, task)
    assert git!(origin, ["branch", "--list", task.worktree_name]) =~ task.worktree_name
    assert %Task{cleaned_up_at: nil} = Repo.reload!(task)
  end

  test "a remote that refuses the delete leaves the worktree, the task and the ticket as they were", %{
    scope: scope,
    task: task,
    issue: %Issue{id: issue_id},
    origin: origin
  } do
    hook = Path.join([origin, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'Repository rule violations found' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    assert {:error, {:branch_not_deleted, output}} = Pipeline.discard_task(scope, task)
    assert output =~ "Repository rule violations found"
    assert File.exists?(task.worktree_path)
    assert %Task{cleaned_up_at: nil} = Repo.reload!(task)
    assert %Issue{state: :in_review, state_name: "In Review"} = Repo.get!(Issue, issue_id)
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

    assert {:ok, %Task{cleaned_up_at: %DateTime{}}} = Pipeline.discard_task(scope, task)
  end

  test "a finished ticket keeps its status and nothing is sent to the tracker", %{scope: scope, task: task, issue: issue} do
    %Issue{id: issue_id} = issue |> Ecto.Changeset.change(state: :canceled, state_name: "Canceled") |> Repo.update!()

    assert {:ok, %Task{cleaned_up_at: %DateTime{}}} = Pipeline.discard_task(scope, task)
    assert %Issue{state: :canceled, state_name: "Canceled"} = Repo.get!(Issue, issue_id)
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

    test "a task merged but still at Finalize keeps its branch", %{scope: scope, task: task, origin: origin} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :finalize, merged_at: DateTime.utc_now()})

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, task)
      assert git!(origin, ["branch", "--list", task.worktree_name]) =~ task.worktree_name
    end

    test "a task whose merge is in progress says so and changes nothing", %{scope: scope, task: task, lead: lead} do
      now = DateTime.utc_now()

      {:ok, task} =
        Pipeline.update_task(task, %{stage: :finalize, marked_ready_at: now, merge_started_at: now, pr_number: 212})

      {:ok, %Run{id: run_id}} =
        Pipeline.create_run(%{task_id: task.id, role_id: lead.id, status: :running, started_at: now})

      assert {:error, :merging} = Pipeline.discard_task(scope, task)
      assert %Run{status: :running} = Repo.get!(Run, run_id)
      refute_received {:pull_request_changed, _number, _body}
    end

    test "a split parent", %{scope: scope, task: task} do
      {:ok, parent} = Pipeline.update_task(task, %{stage: :split})

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, parent)
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
    end

    test "a scope that cannot open the project", %{task: task} do
      assert {:error, :not_found} = Pipeline.discard_task(user_scope(), task)
    end
  end
end
