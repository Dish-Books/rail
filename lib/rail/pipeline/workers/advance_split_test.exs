defmodule Rail.Pipeline.Workers.AdvanceSplitTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    stub(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    # 1 and 2 start at once; 3 waits on both; 4 on 1 alone.
    for {identifier, title} <- [
          {"ASP-1", "Work on ASP-1"},
          {"ASP-2", "Child ASP-2"},
          {"ASP-3", "Child ASP-3"},
          {"ASP-4", "Child ASP-4"},
          {"ASP-5", "Child ASP-5"}
        ] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_#{identifier}", "identifier" => identifier, "title" => title}
            }
          }
        })
      end)
    end

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on ASP-1"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    parent = Repo.preload(parent, [:issue, :project])

    children =
      for {{identifier, builds_on}, number} <-
            Enum.with_index([{"ASP-2", []}, {"ASP-3", []}, {"ASP-4", [1, 2]}, {"ASP-5", [1]}], 1) do
        attrs = %{title: "Child #{identifier}", parent: parent_issue}
        {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)

        part = %{
          number: number,
          builds_on: builds_on,
          builds_screen: false,
          plan: "## Implementation plan\n\nPart #{number}."
        }

        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    merge = fn %Task{issue: issue} ->
      issue |> Issue.linear_changeset(%{state: :done, completed_at: DateTime.utc_now(:second)}) |> Repo.update!()
    end

    %{parent: parent, children: children, merge: merge}
  end

  test "a waiting child starts once every child it builds on has merged, and not while one is short", %{
    parent: parent,
    children: [first, second, third, fourth],
    merge: merge
  } do
    {:ok, engineer} = Roles.get_role(project_id: parent.project_id, stage: :engineer)

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: second.id,
        role_id: engineer.id,
        status: :failed,
        error: "It broke.",
        started_at: DateTime.utc_now()
      })

    merge.(first)
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})

    assert [%Run{}] = Repo.preload(fourth, :runs, force: true).runs
    assert [] = Repo.preload(third, :runs, force: true).runs
    assert %Task{stage: :split} = Repo.reload!(parent)
  end

  test "a child that builds on nothing and has no run is started, as approval leaves it", %{
    parent: parent,
    children: [first, second, third, _fourth]
  } do
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})

    assert [%Run{}] = Repo.preload(first, :runs, force: true).runs
    assert [%Run{}] = Repo.preload(second, :runs, force: true).runs
    assert [] = Repo.preload(third, :runs, force: true).runs
  end

  test "a child that already has a run is not started again", %{
    parent: parent,
    children: [first, _second, _third, fourth],
    merge: merge
  } do
    merge.(first)
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})

    assert [%Run{}] = Repo.preload(fourth, :runs, force: true).runs
  end

  test "the parent moves to Merged only when the last child merges, and its ticket then to Done", %{
    parent: parent,
    children: children,
    merge: merge
  } do
    [last | rest] = Enum.reverse(children)
    Enum.each(rest, merge)
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
    assert %Task{stage: :split} = Repo.reload!(parent)

    merge.(last)
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
    assert %Task{stage: :merged} = Repo.reload!(parent)
    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: parent.issue_id})
  end

  test "a canceled child counts as settled, so the parent moves to Merged once the rest have merged", %{
    parent: parent,
    children: [first | rest],
    merge: merge
  } do
    first.issue |> Issue.linear_changeset(%{state: :canceled}) |> Repo.update!()
    Enum.each(rest, merge)

    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
    assert %Task{stage: :merged} = Repo.reload!(parent)
    assert [] = Repo.preload(first, :runs, force: true).runs
  end

  test "a child building on a canceled sibling is not started, and the parent waits until it is canceled too", %{
    parent: parent,
    children: [first, second, third, fourth],
    merge: merge
  } do
    cancel = &(&1.issue |> Issue.linear_changeset(%{state: :canceled}) |> Repo.update!())
    cancel.(first)
    merge.(second)
    merge.(third)

    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
    assert [] = Repo.preload(fourth, :runs, force: true).runs
    assert %Task{stage: :split} = Repo.reload!(parent)

    cancel.(fourth)
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
    assert %Task{stage: :merged} = Repo.reload!(parent)
  end

  test "a child building on a sibling whose issue Linear removed is never started, and the parent stays open", %{
    project: project,
    parent: parent,
    children: [first, second, third, _fourth],
    merge: merge
  } do
    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)
    remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => second.issue.external_id}}
    assert {:ok, _removed} = Issues.handle_linear_webhook(workspace, remove)
    merge.(first)

    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
    assert [] = Repo.preload(third, :runs, force: true).runs
    assert %Task{stage: :split} = Repo.reload!(parent)
  end

  test "looks again when another child merged while it ran", %{
    parent: parent,
    children: [first, second | _rest],
    merge: merge
  } do
    merge.(first)

    # The other child's merge lands while the waiting one is being started.
    expect(Tools, :start_os_process, fn spawned, _argv ->
      merge.(second)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:snooze, 1} = perform_job(AdvanceSplit, %{parent_task_id: parent.id})
  end

  test "a parent that is gone needs nothing" do
    assert :ok = perform_job(AdvanceSplit, %{parent_task_id: "tsk_gone"})
  end
end
