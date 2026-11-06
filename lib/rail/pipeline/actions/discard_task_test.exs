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
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  # Git is faked at its boundary: deleting a branch or a worktree for real is for `Rail.Git`'s own tests.
  setup %{project: %{id: project_id, github_repo: repo, github_installation_id: installation_id} = project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :delete_remote_branch, fn _project, _branch -> :ok end)
    stub(Git, :remove_worktree, fn _repo_path, _worktree_path -> :ok end)
    stub(Git, :delete_branch, fn _repo_path, _branch -> :ok end)

    # Named per test, since a login two open sandboxes both insert waits on the other's.
    n = System.unique_integer([:positive])
    pull_path = "/repos/#{repo}/pulls/212"
    token_path = "/app/installations/#{installation_id}/access_tokens"

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project_id,
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
    File.mkdir_p!(task.scratch_path)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, engineer} = Roles.get_role(project_id: project_id, stage: :engineer)
    {:ok, lead} = Roles.get_role(project_id: project_id, stage: :review_lead)
    test_pid = self()

    Req.Test.stub(Client, fn
      %{method: "POST", request_path: ^token_path} = conn ->
        Req.Test.json(conn, %{"token" => "ghs_discard"})

      %{method: "GET", request_path: ^pull_path} = conn ->
        Req.Test.json(conn, %{"number" => 212, "state" => "open"})

      %{method: "PATCH", request_path: ^pull_path} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:pull_request_changed, 212, Jason.decode!(body)})
        Req.Test.json(conn, %{"number" => 212, "state" => "closed"})
    end)

    {:ok, reader} =
      Users.register_oauth_user(%{
        github_id: "gh_discard_#{n}",
        login: "discard-reader-#{n}",
        email: "discard-#{n}@example.com"
      })

    %{
      reader: reader,
      repo: repo,
      scope: user_scope(project_ids: [project.id]),
      issue: issue,
      task: task,
      engineer: engineer,
      lead: lead
    }
  end

  test "stops every run, closes the pull request, deletes the branch, files and task, resets the ticket, and a new task for the issue takes the same branch name",
       %{
         scope: scope,
         task: task,
         issue: %Issue{id: issue_id, project: %{id: project_id, clone_path: clone}} = issue,
         engineer: engineer,
         lead: lead,
         reader: reader
       } do
    {:ok, %Task{id: task_id, worktree_name: branch, worktree_path: worktree_path} = task} =
      Pipeline.update_task(task, %{pr_number: 212})

    expect(Git, :delete_remote_branch, fn %{id: ^project_id}, ^branch -> :ok end)
    expect(Git, :remove_worktree, fn ^clone, ^worktree_path -> :ok end)
    expect(Git, :delete_branch, fn ^clone, ^branch -> :ok end)

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
    refute File.exists?(task.scratch_path)
    assert %Issue{state: :todo, state_name: nil} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})

    {:ok, %Task{id: new_id, worktree_name: ^branch}} = Pipeline.create_task(issue, :plan)
    assert new_id != task_id
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

  test "a process still live after the stops leaves everything as it was", %{scope: scope, task: task} do
    stub(Tools, :list_os_processes, fn [task_id: _id, status: _live] -> [%OsProcess{status: :starting}] end)
    reject(Git, :delete_remote_branch, 2)

    assert {:error, :task_busy} = Pipeline.discard_task(scope, task)
    assert %Task{cleaned_up_at: nil} = Repo.reload!(task)
  end

  test "a run still working when the lock is taken leaves everything as it was", %{
    scope: scope,
    task: task,
    engineer: engineer
  } do
    reject(Git, :delete_remote_branch, 2)

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
  end

  test "a remote that refuses the delete leaves the worktree, the task and the ticket as they were", %{
    scope: scope,
    task: task,
    issue: %Issue{id: issue_id},
    engineer: engineer
  } do
    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :failed, started_at: DateTime.utc_now()})

    expect(Git, :delete_remote_branch, fn _project, _branch -> {:error, "remote: Repository rule violations found"} end)
    reject(Git, :remove_worktree, 2)

    assert {:error, {:branch_not_deleted, "remote: Repository rule violations found"}} =
             Pipeline.discard_task(scope, task)

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

    reject(Git, :delete_remote_branch, 2)
    reject(Git, :remove_worktree, 2)

    assert {:error, {:pull_request_not_closed, {:github_api_error, 403, _body}}} =
             Pipeline.discard_task(scope, task)

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
    issue: issue,
    repo: repo
  } do
    pulls_path = "/repos/#{repo}/pulls"
    pull_path = "/repos/#{repo}/pulls/212"

    {:ok, task} = Pipeline.update_task(task, %{pr_number: 212})

    %Issue{id: issue_id} =
      issue
      |> Issue.pull_request_changeset(%{pr_number: 212, pr_url: "https://github.com/#{repo}/pull/212"})
      |> Repo.update!()

    Req.Test.stub(Client, fn
      %{method: "POST"} = conn ->
        Req.Test.json(conn, %{"token" => "ghs_discard"})

      %{method: "GET", request_path: ^pulls_path} = conn ->
        Req.Test.json(conn, [])

      %{method: "GET", request_path: ^pull_path} = conn ->
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

    test "a task merged but still at Finalize keeps its branch", %{scope: scope, task: task} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :finalize, merged_at: DateTime.utc_now()})
      reject(Git, :delete_remote_branch, 2)

      assert {:error, :not_discardable} = Pipeline.discard_task(scope, task)
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
