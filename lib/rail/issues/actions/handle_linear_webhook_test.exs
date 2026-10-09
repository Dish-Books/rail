defmodule Rail.Issues.Actions.HandleLinearWebhookTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    %{workspace: workspace}
  end

  test "an issue create mirrors the issue onto the workspace's project", %{
    project: %Project{id: project_id},
    workspace: workspace
  } do
    assert {:ok, %Issue{id: "iss_" <> _id}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "create",
               "data" => %{
                 "id" => "lin_wh_1",
                 "teamId" => "lin_team_id",
                 "identifier" => "HWH-1",
                 "title" => "Webhook Issue",
                 "description" => "Created via webhook",
                 "priority" => 2,
                 "state" => %{"id" => "st_started", "name" => "In Progress", "type" => "started"},
                 "branchName" => "hwh-1-webhook",
                 "url" => "https://linear.app/issue/HWH-1"
               }
             })

    assert %Issue{
             project_id: ^project_id,
             identifier: "HWH-1",
             title: "Webhook Issue",
             description: "Created via webhook",
             priority: :high,
             state: :in_progress,
             state_name: "In Progress",
             branch_name: "hwh-1-webhook",
             url: "https://linear.app/issue/HWH-1"
           } = Repo.get_by(Issue, external_id: "lin_wh_1")
  end

  test "an issue update changes the existing row and pushes nothing back to Linear", %{
    project: project,
    workspace: workspace
  } do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_2",
        identifier: "HWH-2",
        title: "Initial Title",
        state: :triage
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Issue{id: ^issue_id, title: "Updated Title", state: :done}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "lin_wh_2",
                 "teamId" => "lin_team_id",
                 "identifier" => "HWH-2",
                 "title" => "Updated Title",
                 "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"}
               }
             })

    assert_receive {:issue_changed, ^issue_id}
    refute_enqueued(worker: SyncIssue)
  end

  test "an issue marked Duplicate in Linear leaves the default list, as a canceled one does", %{
    project: project,
    workspace: workspace
  } do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_dup",
        identifier: "HWH-9",
        title: "Same as HWH-2",
        state: :triage
      })
      |> Repo.insert!()

    assert %{issues: [%Issue{id: ^issue_id}]} = Issues.list_issues(project_id: project.id)

    assert {:ok, %Issue{id: ^issue_id, state: :duplicate, state_name: "Duplicate"}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "lin_wh_dup",
                 "teamId" => "lin_team_id",
                 "identifier" => "HWH-9",
                 "title" => "Same as HWH-2",
                 "state" => %{"id" => "st_dup", "name" => "Duplicate", "type" => "duplicate"}
               }
             })

    assert %{issues: [], total: 0} = Issues.list_issues(project_id: project.id)
    refute_enqueued(worker: SyncIssue)
  end

  test "an issue update sets its owner to the Rail user linked to the assignee, and unassigning clears it", %{
    project: project,
    workspace: workspace
  } do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_wh_assignee", login: "wh_assignee", email: "wh_assignee@example.com"})

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_wh_assignee") |> Repo.update!()

    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_owner",
        identifier: "HWH-9",
        title: "Owner Issue",
        state: :triage
      })
      |> Repo.insert!()

    data = %{"id" => "lin_wh_owner", "teamId" => "lin_team_id", "identifier" => "HWH-9", "title" => "Owner Issue"}

    assert {:ok, %Issue{owner_user_id: ^user_id}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => Map.put(data, "assigneeId", "lin_usr_wh_assignee")
             })

    # It had no owner, so its Linear status was held back and now catches up with its task.
    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: issue_id})

    assert {:ok, %Issue{owner_user_id: nil}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => Map.put(data, "assigneeId", nil)
             })
  end

  test "an assignee change on a split parent reaches its children", %{project: project, workspace: workspace} do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_wh_parent", login: "wh_parent", email: "wh_parent@example.com"})

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_wh_parent") |> Repo.update!()

    for {identifier, title} <- [{"HWH-30", "Work on HWH-30"}, {"HWH-31", "Child HWH-31"}] do
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

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on HWH-30"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    parent = Repo.preload(parent, [:issue, :project])

    [child] =
      for {{identifier, builds_on}, number} <- Enum.with_index([{"HWH-31", []}], 1) do
        attrs = %{title: "Child #{identifier}", parent: parent_issue}
        {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
        part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    data = %{
      "id" => parent_issue.external_id,
      "teamId" => "lin_team_id",
      "identifier" => "HWH-30",
      "title" => "Work on HWH-30",
      "assigneeId" => "lin_usr_wh_parent"
    }

    assert {:ok, %Issue{owner_user_id: ^user_id}} =
             Issues.handle_linear_webhook(workspace, %{"type" => "Issue", "action" => "update", "data" => data})

    assert %Issue{owner_user_id: ^user_id} = Repo.reload!(child.issue)
    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: parent_issue.id})
    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: child.issue_id})
  end

  test "an issue update older than the one already applied is dropped, whichever arrives first", %{
    project: project,
    workspace: workspace
  } do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_wh_order", login: "wh_order", email: "wh_order@example.com"})

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_wh_order") |> Repo.update!()

    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_order",
        identifier: "HWH-40",
        title: "Out of order",
        state: :backlog
      })
      |> Repo.insert!()

    data = %{"id" => "lin_wh_order", "teamId" => "lin_team_id", "identifier" => "HWH-40", "title" => "Out of order"}

    # Linear moved the ticket to In Progress, then assigned it 250 ms later. Each event carries the whole ticket.
    state_change =
      Map.merge(data, %{
        "state" => %{"id" => "st_started", "name" => "In Progress", "type" => "started"},
        "updatedAt" => "2026-10-08T15:00:00.000Z"
      })

    assignee_change =
      Map.merge(state_change, %{"assigneeId" => "lin_usr_wh_order", "updatedAt" => "2026-10-08T15:00:00.250Z"})

    assert {:ok, %Issue{state: :in_progress, owner_user_id: ^user_id}} =
             Issues.handle_linear_webhook(workspace, %{"type" => "Issue", "action" => "update", "data" => assignee_change})

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert :ok =
             Issues.handle_linear_webhook(workspace, %{"type" => "Issue", "action" => "update", "data" => state_change})

    refute_receive {:issue_changed, ^issue_id}

    assert %Issue{state: :in_progress, owner_user_id: ^user_id, linear_updated_at: ~U[2026-10-08 15:00:00.250000Z]} =
             Repo.get!(Issue, issue_id)

    # The same event sent again, and one with no time on it, are still applied.
    assert {:ok, %Issue{title: "Renamed"}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => Map.put(assignee_change, "title", "Renamed")
             })

    assert {:ok, %Issue{title: "Renamed again"}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => assignee_change |> Map.delete("updatedAt") |> Map.put("title", "Renamed again")
             })
  end

  test "an issue remove deletes the row and its task, broadcasts, and a second remove is a no-op", %{
    project: project,
    workspace: workspace
  } do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_3",
        identifier: "HWH-3",
        title: "Doomed",
        state: :triage
      })
      |> Repo.insert!()

    issue = Repo.preload(issue, :project)
    {:ok, earlier} = Pipeline.create_task(issue, :merged)
    {:ok, %Task{id: earlier_id}} = Pipeline.update_task(earlier, %{cleaned_up_at: DateTime.utc_now()})
    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue, :plan)
    {:ok, plan} = Roles.get_role(project_id: project.id, stage: :plan)

    runs =
      for id <- [earlier_id, task_id] do
        {:ok, %Run{id: run_id}} =
          Pipeline.create_run(%{task_id: id, role_id: plan.id, status: :finished, started_at: DateTime.utc_now()})

        run_id
      end

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => "lin_wh_3"}}

    assert {:ok, %Issue{id: ^issue_id}} = Issues.handle_linear_webhook(workspace, remove)
    assert_receive {:issue_changed, ^issue_id}
    # Its turns are gone, and Sandboxes hears so only once the issue is too.
    assert_receive :sandboxes_changed
    assert Repo.get(Issue, issue_id) == nil
    assert Repo.get(Task, task_id) == nil
    # Runs have no foreign key to their task, a cleaned-up one's included.
    assert [] = Repo.all(from(r in Run, where: r.id in ^runs))

    assert :ok = Issues.handle_linear_webhook(workspace, remove)
    refute_receive {:issue_changed, ^issue_id}, 50
  end

  # Its own project, because the worktree is removed from a real clone.
  test "a remove takes its task's worktree, branch and scratch folder with it", %{workspace: %{id: workspace_id}} do
    clone_path = create_temp_git_repo(prefix: "rail_wh_remove_main")
    worktree_path = Path.join(System.tmp_dir!(), "rail_wh_remove_wt_#{System.unique_integer([:positive])}")
    git!(clone_path, ["worktree", "add", "-b", "wh-remove-branch", worktree_path])
    scratch_dir = Path.join(System.tmp_dir!(), "rail_wh_remove_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_wh_remove"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Remove Project",
        github_repo: "org/wh-remove",
        github_installation_id: 12_955,
        linear_team_key: "WHR",
        default_branch: "main",
        clone_path: clone_path,
        linear_workspace_id: workspace_id
      })

    {:ok, task} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_remove_files",
        identifier: "WHR-1",
        title: "Removed with its worktree",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Repo.preload(:project)
      |> Pipeline.create_task(:engineer)

    {:ok, _task} =
      Pipeline.update_task(task, %{
        worktree_name: "wh-remove-branch",
        worktree_path: worktree_path,
        scratch_path: scratch_dir
      })

    {:ok, workspace} = Projects.get_linear_workspace(id: workspace_id)
    remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => "lin_wh_remove_files"}}

    assert {:ok, %Issue{}} = Issues.handle_linear_webhook(workspace, remove)

    refute File.exists?(worktree_path)
    refute File.exists?(scratch_dir)
    assert "" = git!(clone_path, ["branch", "--list", "wh-remove-branch"])
  end

  test "an update marked trashed deletes the issue and its task, whatever team it names", %{
    project: project,
    workspace: workspace
  } do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_trash",
        identifier: "HWH-30",
        title: "Trashed",
        state: :todo
      })
      |> Repo.insert!()

    {:ok, %Task{id: task_id}} = issue |> Repo.preload(:project) |> Pipeline.create_task(:plan)
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    # Trashed wins over archived, so the task does not keep it.
    assert {:ok, %Issue{id: ^issue_id}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "lin_wh_trash",
                 "teamId" => "lin_team_unclaimed",
                 "identifier" => "HWH-30",
                 "title" => "Trashed",
                 "trashed" => true,
                 "archivedAt" => "2026-10-06T10:00:00.000Z"
               }
             })

    assert_receive {:issue_changed, ^issue_id}
    assert Repo.get(Issue, issue_id) == nil
    assert Repo.get(Task, task_id) == nil
  end

  test "an archive deletes an issue with no task and broadcasts, and inserts nothing for one Rail never had", %{
    project: project,
    workspace: workspace
  } do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_archived",
        identifier: "HWH-31",
        title: "Archived",
        state: :done
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    archive = fn external_id ->
      Issues.handle_linear_webhook(workspace, %{
        "type" => "Issue",
        "action" => "update",
        "data" => %{
          "id" => external_id,
          "teamId" => "lin_team_id",
          "identifier" => "HWH-31",
          "title" => "Archived",
          "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"},
          "archivedAt" => "2026-10-06T10:00:00.000Z",
          "trashed" => nil
        }
      })
    end

    assert {:ok, %Issue{id: ^issue_id}} = archive.("lin_wh_archived")
    assert_receive {:issue_changed, ^issue_id}
    assert Repo.get(Issue, issue_id) == nil

    assert :ok = archive.("lin_wh_never_had")
    assert Repo.get_by(Issue, external_id: "lin_wh_never_had") == nil
  end

  test "an archive keeps an issue with a task, even a cleaned-up one, and upserts it as any update", %{
    project: project,
    workspace: workspace
  } do
    insert = fn external_id ->
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: external_id,
        identifier: external_id,
        title: "Kept",
        state: :in_review
      })
      |> Repo.insert!()
      |> Repo.preload(:project)
    end

    %Issue{id: live_id} = live = insert.("lin_wh_kept")
    {:ok, %Task{id: task_id}} = Pipeline.create_task(live, :engineer)

    %Issue{id: cleaned_id} = cleaned = insert.("lin_wh_kept_cleaned")
    {:ok, task} = Pipeline.create_task(cleaned, :merged)
    {:ok, _cleaned_task} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    archive = fn external_id ->
      Issues.handle_linear_webhook(workspace, %{
        "type" => "Issue",
        "action" => "update",
        "data" => %{
          "id" => external_id,
          "teamId" => "lin_team_id",
          "identifier" => external_id,
          "title" => "Kept and closed",
          "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"},
          "archivedAt" => "2026-10-06T10:00:00.000Z"
        }
      })
    end

    assert {:ok, %Issue{id: ^live_id, title: "Kept and closed", state: :done}} = archive.("lin_wh_kept")
    assert {:ok, %Issue{id: ^cleaned_id, state: :done}} = archive.("lin_wh_kept_cleaned")
    assert %Task{issue_id: ^live_id} = Repo.get(Task, task_id)

    assert %{issues: [%Issue{id: ^cleaned_id}, %Issue{id: ^live_id}]} =
             Issues.list_issues(project_id: project.id, show_finished: true)
  end

  test "an update moving an issue with a task to a team no project is on leaves it as it was", %{
    project: %Project{id: project_id},
    workspace: workspace
  } do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project_id,
        external_id: "lin_wh_moved",
        identifier: "HWH-32",
        title: "Moved",
        state: :todo
      })
      |> Repo.insert!()

    {:ok, _task} = issue |> Repo.preload(:project) |> Pipeline.create_task(:plan)

    assert :ok =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "lin_wh_moved",
                 "teamId" => "lin_team_elsewhere",
                 "identifier" => "ELS-1",
                 "title" => "Moved away",
                 "archivedAt" => "2026-10-06T10:00:00.000Z"
               }
             })

    assert %Issue{id: ^issue_id, project_id: ^project_id, identifier: "HWH-32"} = Repo.get(Issue, issue_id)
  end

  test "a remove for an issue on a project outside the workspace leaves it in place", %{workspace: workspace} do
    {:ok, %Project{id: other_project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Unlinked Project",
        github_repo: "org/unlinked",
        github_installation_id: 12_952,
        linear_team_key: "UNL",
        default_branch: "main",
        clone_path: "/tmp/repos/unlinked"
      })

    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: other_project_id,
        external_id: "lin_wh_elsewhere",
        identifier: "UNL-1",
        title: "Not this workspace's",
        state: :todo
      })
      |> Repo.insert!()

    remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => "lin_wh_elsewhere"}}

    assert :ok = Issues.handle_linear_webhook(workspace, remove)
    assert %Issue{id: ^issue_id} = Repo.get(Issue, issue_id)
  end

  test "a remove for a split parent's issue leaves the parent and its children in place", %{
    project: project,
    workspace: workspace
  } do
    for {identifier, title} <- [{"HWH-20", "Work on HWH-20"}, {"HWH-21", "Child HWH-21"}] do
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

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on HWH-20"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    parent = Repo.preload(parent, [:issue, :project])

    [child] =
      for {{identifier, builds_on}, number} <- Enum.with_index([{"HWH-21", []}], 1) do
        attrs = %{title: "Child #{identifier}", parent: parent_issue}
        {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
        part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => parent_issue.external_id}}

    assert :ok = Issues.handle_linear_webhook(workspace, remove)
    assert Repo.reload(parent_issue)
    assert Repo.reload(parent)
    assert Repo.reload(child)
  end

  test "an issue goes to the project on its team when the workspace has several", %{
    project: %Project{id: project_id},
    workspace: %{id: workspace_id}
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_other"}]}}})
    end)

    {:ok, %Project{id: other_project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Other Team Project",
        github_repo: "org/other-team",
        github_installation_id: 12_951,
        linear_team_key: "OTH",
        default_branch: "main",
        clone_path: "/tmp/repos/other-team",
        linear_workspace_id: workspace_id
      })

    {:ok, workspace} = Projects.get_linear_workspace(id: workspace_id)

    issue = fn id, team_id ->
      %{
        "type" => "Issue",
        "action" => "create",
        "data" => %{"id" => id, "identifier" => id, "title" => id, "teamId" => team_id}
      }
    end

    assert {:ok, %Issue{project_id: ^project_id}} =
             Issues.handle_linear_webhook(workspace, issue.("HWH-5", "lin_team_id"))

    assert {:ok, %Issue{project_id: ^other_project_id}} =
             Issues.handle_linear_webhook(workspace, issue.("OTH-1", "lin_team_other"))

    assert :ok = Issues.handle_linear_webhook(workspace, issue.("NOP-1", "lin_team_unclaimed"))
    assert Repo.get_by(Issue, external_id: "NOP-1") == nil
  end

  test "an issue on a team no project is on and events that are not issues change nothing", %{workspace: workspace} do
    event = %{
      "type" => "Issue",
      "action" => "create",
      "data" => %{"id" => "lin_wh_4", "identifier" => "HWH-4", "title" => "Orphan", "teamId" => "lin_team_unclaimed"}
    }

    assert :ok = Issues.handle_linear_webhook(workspace, event)
    assert :ok = Issues.handle_linear_webhook(workspace, %{"type" => "Project", "action" => "create", "data" => %{}})
    assert Repo.get_by(Issue, external_id: "lin_wh_4") == nil
  end

  test "comment creates, replies, updates and removes mirror onto the issue", %{project: project, workspace: workspace} do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_5",
        identifier: "HWH-5",
        title: "Discussed",
        state: :triage
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Comment{id: parent_id, issue_id: ^issue_id, parent_id: nil, body: "Open question"}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Comment",
               "action" => "create",
               "data" => %{
                 "id" => "lin_wh_com_1",
                 "body" => "Open question",
                 "issueId" => "lin_wh_5",
                 "userId" => "lin_usr_nobody",
                 "createdAt" => "2026-09-09T10:00:00.000Z"
               }
             })

    assert_receive {:issue_comments_changed, ^issue_id}

    reply = %{
      "type" => "Comment",
      "action" => "create",
      "data" => %{"id" => "lin_wh_com_2", "body" => "yes", "issueId" => "lin_wh_5", "parentId" => "lin_wh_com_1"}
    }

    assert {:ok, %Comment{parent_id: ^parent_id}} = Issues.handle_linear_webhook(workspace, reply)

    assert {:ok, %Comment{id: ^parent_id, body: "Edited question"}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Comment",
               "action" => "update",
               "data" => %{"id" => "lin_wh_com_1", "body" => "Edited question", "issueId" => "lin_wh_5"}
             })

    remove = %{"type" => "Comment", "action" => "remove", "data" => %{"id" => "lin_wh_com_1"}}

    assert {:ok, %Comment{}} = Issues.handle_linear_webhook(workspace, remove)
    # The thread's replies go with it.
    assert [] = Repo.all(Comment)
    assert :ok = Issues.handle_linear_webhook(workspace, remove)
  end

  test "a comment on an issue or thread Rail has not synced yet is left for the next sync", %{workspace: workspace} do
    assert :ok =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Comment",
               "action" => "create",
               "data" => %{"id" => "lin_wh_com_3", "body" => "Early", "issueId" => "lin_unsynced"}
             })

    assert [] = Repo.all(Comment)
  end

  describe "an issue finishing" do
    setup %{project: project, workspace: workspace} do
      update = fn external_id, state_type ->
        Issues.handle_linear_webhook(workspace, %{
          "type" => "Issue",
          "action" => "update",
          "data" => %{
            "id" => external_id,
            "teamId" => "lin_team_id",
            "identifier" => "HWH-F",
            "title" => "Finishing",
            "state" => %{"id" => "st_#{state_type}", "name" => state_type, "type" => state_type}
          }
        })
      end

      insert = fn external_id, state ->
        %Issue{}
        |> Issue.linear_changeset(%{
          project_id: project.id,
          external_id: external_id,
          identifier: "HWH-F",
          title: "Finishing",
          state: state
        })
        |> Repo.insert!()
      end

      %{update: update, insert: insert}
    end

    test "an update into done hands the issue to Learnings once", %{update: update, insert: insert} do
      %Issue{id: issue_id} = insert.("lin_fin_1", :in_review)

      assert {:ok, %Issue{state: :done}} = update.("lin_fin_1", "completed")
      assert {:ok, %Issue{state: :done}} = update.("lin_fin_1", "completed")

      assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
    end

    test "a split child completing queues its parent's next step", %{project: project, update: update} do
      for {identifier, title} <- [{"HWH-10", "Work on HWH-10"}, {"HWH-11", "Child HWH-11"}] do
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

      {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on HWH-10"})
      {:ok, parent} = Pipeline.create_task(parent_issue, :split)
      parent = Repo.preload(parent, [:issue, :project])

      [child] =
        for {{identifier, builds_on}, number} <- Enum.with_index([{"HWH-11", []}], 1) do
          attrs = %{title: "Child #{identifier}", parent: parent_issue}
          {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
          part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
          {:ok, child} = Pipeline.create_child_task(parent, issue, part)
          Repo.preload(child, [:issue, :project])
        end

      assert {:ok, %Issue{state: :done}} = update.(child.issue.external_id, "completed")
      assert_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent.id})
    end

    test "an update between two open states or two finished states does not", %{update: update, insert: insert} do
      insert.("lin_fin_2", :todo)
      insert.("lin_fin_3", :done)

      assert {:ok, %Issue{state: :in_progress}} = update.("lin_fin_2", "started")
      assert {:ok, %Issue{state: :canceled}} = update.("lin_fin_3", "canceled")

      refute_enqueued(worker: IssueFinished)
      refute_enqueued(worker: AdvanceSplit)
    end
  end
end
