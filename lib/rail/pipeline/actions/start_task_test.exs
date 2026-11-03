defmodule Rail.Pipeline.Actions.StartTaskTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Issues.Tracker
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :branch_fingerprint, fn _worktree_path -> nil end)

    attrs = %{
      project_id: project.id,
      external_id: "lin_start_task",
      identifier: "STK-1",
      title: "Flaky test sweep 2026-10-10",
      description: "Make each flaky test deterministic.",
      state: :todo
    }

    [starter, teammate] =
      Enum.map(["starter", "teammate"], fn login ->
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "gh_#{login}_start_task",
            login: "#{login}-start-task",
            email: "#{login}-start-task@example.com"
          })

        {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
        user |> Ecto.Changeset.change(linear_user_id: "lin_usr_#{login}") |> Repo.update!()
      end)

    %{attrs: attrs, starter: starter, teammate: teammate}
  end

  test "a hand-filed issue starts at Plan with one Plan run", %{project: project, attrs: attrs} do
    issue = %Issue{} |> Issue.tracker_changeset(attrs) |> Repo.insert!()
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: project.id, stage: :plan)

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{id: task_id, stage: :plan, runs: [%Run{role_id: ^role_id}]}} =
             Pipeline.start_task(system_scope(), issue)

    assert [%Run{role_id: ^role_id}] = Repo.all(from r in Run, where: r.task_id == ^task_id)
    assert [] = Repo.all(from r in Round, where: r.task_id == ^task_id)
  end

  test "an issue with every Plan step off starts at Engineer, with the issue as an approved round 1's ticket", %{
    project: project,
    attrs: attrs
  } do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    {:ok, %Role{id: engineer_id}} = Roles.get_role(project_id: project.id, stage: :engineer)

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{id: task_id, stage: :engineer}} = Pipeline.start_task(system_scope(), issue)
    assert [%Run{role_id: ^engineer_id}] = Repo.all(from r in Run, where: r.task_id == ^task_id)

    assert [
             %Round{
               number: 1,
               plan: nil,
               approved_at: %DateTime{},
               approved_by_id: nil,
               ticket: %Round.Ticket{
                 title: "Flaky test sweep 2026-10-10",
                 description: "Make each flaky test deterministic."
               }
             }
           ] = Repo.all(from r in Round, where: r.task_id == ^task_id)
  end

  test "a second start of an Engineer task, as from another tab, makes no second round", %{attrs: attrs} do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    expect(Tools, :start_os_process, 1, fn %Run{} = run, _argv ->
      {:ok, %OsProcess{task_id: run.task_id, run: run}}
    end)

    assert {:ok, %Task{id: task_id}} = Pipeline.start_task(system_scope(), issue)
    assert {:error, :task_exists} = Pipeline.start_task(system_scope(), issue)
    assert [%Round{number: 1}] = Repo.all(from r in Round, where: r.task_id == ^task_id)
  end

  test "an Engineer start whose worktree cannot be made leaves the issue without a task", %{attrs: attrs} do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, :clone_missing} end)
    reject(Tools, :start_os_process, 2)

    assert {:error, {:worktree_failed, :clone_missing}} = Pipeline.start_task(system_scope(), issue)
    assert [] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
  end

  test "the person who starts an unassigned issue at Plan owns it, and its ticket moves to In Progress", %{
    attrs: attrs,
    starter: %{id: starter_id} = starter
  } do
    %{id: issue_id} = issue = %Issue{} |> Issue.tracker_changeset(attrs) |> Repo.insert!()
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)
    expect(Tracker.Linear, :advance_issue, fn %Issue{id: ^issue_id, owner_user_id: ^starter_id}, :in_progress -> :ok end)

    assert {:ok, %Task{stage: :plan}} = Pipeline.start_task(Scope.for_user(starter), issue)

    assert %Issue{owner_user_id: ^starter_id} = Repo.reload!(issue)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id, fields: ["owner_user_id"]})
    assert_received {:issue_changed, ^issue_id}
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
  end

  test "a person starting a GitHub issue owns it without a Linear account, and its label moves", %{
    github_project: project
  } do
    {:ok, starter} =
      Users.register_oauth_user(%{github_id: "gh_st_gh", login: "st-gh", email: "st-gh@example.com"})

    {:ok, %{id: starter_id} = starter} = Users.update_user(system_scope(), starter, %{project_ids: [project.id]})
    %{id: issue_id} = issue = github_issue(project)

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)
    expect(Tracker.Github, :advance_issue, fn %Issue{id: ^issue_id, owner_user_id: ^starter_id}, :in_progress -> :ok end)

    assert {:ok, %Task{stage: :plan}} = Pipeline.start_task(Scope.for_user(starter), issue)

    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id, fields: ["owner_user_id"]})
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
  end

  test "the person who starts an unassigned issue at Engineer owns it, and its ticket moves to In Progress", %{
    attrs: attrs,
    starter: %{id: starter_id} = starter
  } do
    %{id: issue_id} =
      issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)
    expect(Tracker.Linear, :advance_issue, fn %Issue{id: ^issue_id, owner_user_id: ^starter_id}, :in_progress -> :ok end)

    assert {:ok, %Task{stage: :engineer}} = Pipeline.start_task(Scope.for_user(starter), issue)

    assert %Issue{owner_user_id: ^starter_id} = Repo.reload!(issue)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id, fields: ["owner_user_id"]})
    assert_received {:issue_changed, ^issue_id}
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
  end

  test "an Engineer start tells open pages again once its run exists, so they do not stay at Queued", %{
    attrs: attrs,
    starter: starter
  } do
    %{id: issue_id} =
      issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    expect(Tools, :start_os_process, fn %Run{} = run, _argv ->
      assert_received {:issue_changed, ^issue_id}
      refute_received {:issue_changed, ^issue_id}
      {:ok, %OsProcess{task_id: run.task_id, run: run}}
    end)

    assert {:ok, %Task{}} = Pipeline.start_task(Scope.for_user(starter), issue)
    assert_received {:issue_changed, ^issue_id}
  end

  test "the person who starts an issue at a custom stage owns it, and its ticket moves to In Progress", %{
    attrs: attrs,
    starter: %{id: starter_id} = starter
  } do
    stages = [
      %IssueStage{stage: :custom, name: "Missing strings", prompt: "List the keys with no translation."},
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :review}
    ]

    %{id: issue_id} = issue = %Issue{stages: stages} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)
    expect(Tracker.Linear, :advance_issue, fn %Issue{id: ^issue_id, owner_user_id: ^starter_id}, :in_progress -> :ok end)

    assert {:ok, %Task{stage: :custom}} = Pipeline.start_task(Scope.for_user(starter), issue)

    assert %Issue{owner_user_id: ^starter_id} = Repo.reload!(issue)
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
  end

  test "an issue a teammate owns keeps that owner, and the page still hears of the start", %{
    attrs: attrs,
    starter: starter,
    teammate: %{id: teammate_id}
  } do
    %{id: issue_id} = issue = %Issue{} |> Issue.tracker_changeset(attrs) |> Repo.insert!()
    issue = issue |> Ecto.Changeset.change(owner_user_id: teammate_id) |> Repo.update!()
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{}} = Pipeline.start_task(Scope.for_user(starter), issue)

    assert %Issue{owner_user_id: ^teammate_id} = Repo.reload!(issue)
    refute_enqueued(worker: SyncIssue)
    assert_received {:issue_changed, ^issue_id}
  end

  test "a second person starting the same issue at Plan is refused, and the first keeps the task and ownership", %{
    attrs: attrs,
    starter: %{id: starter_id} = starter,
    teammate: teammate
  } do
    issue = %Issue{} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{id: task_id}} = Pipeline.start_task(Scope.for_user(starter), issue)
    assert {:error, :task_exists} = Pipeline.start_task(Scope.for_user(teammate), issue)

    assert [%Task{id: ^task_id}] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
    assert %Issue{owner_user_id: ^starter_id} = Repo.reload!(issue)
  end

  test "a second person starting the same issue at Engineer is refused, and the first keeps the task and ownership", %{
    attrs: attrs,
    starter: %{id: starter_id} = starter,
    teammate: teammate
  } do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{id: task_id}} = Pipeline.start_task(Scope.for_user(starter), issue)
    assert {:error, :task_exists} = Pipeline.start_task(Scope.for_user(teammate), issue)

    assert [%Task{id: ^task_id}] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
    assert %Issue{owner_user_id: ^starter_id} = Repo.reload!(issue)
  end

  test "a person who never linked Linear still starts the task, with the issue left unassigned", %{
    project: project,
    attrs: attrs
  } do
    issue = %Issue{} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    {:ok, unlinked} =
      Users.register_oauth_user(%{github_id: "gh_st_none", login: "st-none", email: "st-none@example.com"})

    {:ok, unlinked} = Users.update_user(system_scope(), unlinked, %{project_ids: [project.id]})

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{}} = Pipeline.start_task(Scope.for_user(unlinked), issue)

    assert %Issue{owner_user_id: nil} = Repo.reload!(issue)
    refute_enqueued(worker: SyncIssue)
  end

  test "a person whose start cannot make a worktree owns nothing, at Plan or at Engineer", %{
    attrs: attrs,
    starter: starter
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    scope = Scope.for_user(starter)

    # No transaction is open while git fetches, so nothing is recorded or claimed yet in here.
    stub(Git, :get_or_create_worktree, fn _project, %Task{issue_id: issue_id} ->
      refute Repo.in_transaction?()
      refute Repo.exists?(from t in Task, where: t.issue_id == ^issue_id)
      assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue_id)
      {:error, :clone_missing}
    end)

    reject(Tools, :start_os_process, 2)

    for {skipped_steps, number} <- [{[], 1}, {[:product, :design, :architect], 2}] do
      %{id: issue_id} =
        issue =
        %Issue{skipped_steps: skipped_steps}
        |> Issue.tracker_changeset(%{attrs | external_id: "lin_no_tree_#{number}", identifier: "STK-1#{number}"})
        |> Repo.insert!()

      assert {:error, {:worktree_failed, :clone_missing}} = Pipeline.start_task(scope, issue)

      assert %Issue{owner_user_id: nil} = Repo.reload!(issue)
      assert [] = Repo.all(from t in Task, where: t.issue_id == ^issue_id)
      refute_received {:issue_changed, ^issue_id}
    end

    refute_enqueued(worker: SyncIssue)
    refute_enqueued(worker: AdvanceTrackerState)
  end

  test "a task another start records while git runs refuses this one at Engineer, which records nothing", %{
    attrs: attrs,
    starter: starter
  } do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    expect(Git, :get_or_create_worktree, fn _project, task ->
      {:ok, _theirs} = Pipeline.create_task(Repo.preload(issue, :project), :engineer)
      {:ok, task.worktree_path}
    end)

    reject(Tools, :start_os_process, 2)

    assert {:error, :task_exists} = Pipeline.start_task(Scope.for_user(starter), issue)

    assert [%Task{id: task_id}] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
    assert [] = Repo.all(from r in Round, where: r.task_id == ^task_id)
    assert %Issue{owner_user_id: nil} = Repo.reload!(issue)
  end

  test "a project the person cannot access is refused and nothing starts", %{attrs: attrs} do
    issue = %Issue{} |> Issue.tracker_changeset(attrs) |> Repo.insert!()
    reject(Git, :get_or_create_worktree, 2)

    assert {:error, :not_found} = Pipeline.start_task(user_scope(project_ids: []), issue)

    assert [] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
  end

  test "an issue whose sequence starts with a custom stage starts there, on its own role, with no round", %{
    project: project,
    attrs: attrs
  } do
    stages = [
      %IssueStage{stage: :custom, name: "Missing strings", prompt: "List the keys with no translation."},
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :review}
    ]

    issue = %Issue{stages: stages} |> Issue.tracker_changeset(attrs) |> Repo.insert!()
    {:ok, %Role{id: engineer_id}} = Roles.get_role(project_id: project.id, stage: :engineer)

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    expect(Tools, :start_os_process, fn %Run{} = run, argv ->
      assert "List the keys with no translation." in argv
      {:ok, %OsProcess{task_id: run.task_id, run: run}}
    end)

    assert {:ok, %Task{id: task_id, stage: :custom, custom_stage: "Missing strings"}} =
             Pipeline.start_task(system_scope(), issue)

    assert [%Run{role: %Role{custom_stage: "Missing strings", id: role_id}}] =
             Repo.all(from r in Run, where: r.task_id == ^task_id, preload: :role)

    assert role_id != engineer_id
    assert [] = Repo.all(from r in Round, where: r.task_id == ^task_id)
  end
end
