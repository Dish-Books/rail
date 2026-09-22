defmodule Rail.Pipeline.Actions.CleanupTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cleanup Task Project 8701",
        github_repo: "org/cleanup-task-8701",
        github_installation_id: 8701,
        linear_workspace: %{
          name: "Cleanup Task Workspace",
          external_id: "lin_ws_cleanup_task",
          token: "lin_api_token_cleanup_task",
          webhook_secret: "whsec_cleanup_task"
        },
        linear_team_key: "P8701",
        default_branch: "main",
        clone_path: "/tmp/repos/cleanup-task-8701",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_cleanup_task_1",
              "identifier" => "CLT-1",
              "title" => "Cleanup Task Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Cleanup Task Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "refuses to clean up while the stage's run is still working", %{task: task, roles: roles} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    {:ok, _running} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :task_busy} = Pipeline.cleanup_task(task)
  end

  test "cleans up worktree, branch and scratch directory, and broadcasts", %{
    project: _project,
    task: _task
  } do
    clone_path = create_temp_git_repo(prefix: "rail_cleanup_main")
    wt_dir = Path.join(System.tmp_dir!(), "rail_cleanup_wt_#{System.unique_integer([:positive])}")

    {:ok, worktree_path} =
      Git.get_or_create_worktree(%Project{clone_path: clone_path, default_branch: "main"}, %Task{
        worktree_path: wt_dir,
        worktree_name: "cleanup-branch"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        linear_workspace: %{
          name: "Cleanup Task Workspace",
          external_id: "lin_ws_cleanup_task_x4",
          token: "lin_api_token_cleanup_task",
          webhook_secret: "whsec_cleanup_task"
        },
        name: "Cleanup Task Project 8705",
        github_repo: "org/cleanup-task-8705",
        github_installation_id: 8705,
        linear_team_key: "P8705",
        default_branch: "main",
        clone_path: clone_path,
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    scratch_dir = Path.join(System.tmp_dir!(), "rail_cleanup_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    File.write!(Path.join(scratch_dir, "scratch.txt"), "temporary content")

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_cleanup_task_8707",
              "identifier" => "TSK-8707",
              "title" => "Task 8707"
            }
          }
        }
      })
    end)

    {:ok, issue_8707} = Issues.create_issue(system_scope(), project, %{description: "Task 8707"})

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_8707, :product)

    {:ok, %Task{} = task} =
      Pipeline.update_task(task, %{
        stage: :merged,
        worktree_name: "cleanup-branch",
        worktree_path: worktree_path,
        scratch_path: scratch_dir
      })

    assert {:ok, %Task{worktree_path: ^worktree_path} = cleaned} =
             Pipeline.cleanup_task(task)

    refute Task.worktree_present?(cleaned)

    refute File.exists?(worktree_path)
    refute File.exists?(scratch_dir)
  end

  test "keeps the task as history but frees its issue to be started again", %{task: task, issue: issue} do
    assert {:ok, %Task{cleaned_up_at: %DateTime{}}} = Pipeline.cleanup_task(task)

    assert {:ok, %Task{cleaned_up_at: %DateTime{}}} = Pipeline.get_task(task.id)
    assert {:ok, %Task{id: new_id, cleaned_up_at: nil}} = Pipeline.create_task(issue, :product)
    refute new_id == task.id
    assert %{task: %Task{id: ^new_id}} = Repo.preload(issue, :task, force: true)
  end

  test "handles cleanup gracefully when worktree_path is already nil", %{project: _project, task: _task} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        linear_workspace: %{
          name: "Cleanup Task Workspace",
          external_id: "lin_ws_cleanup_task_x5",
          token: "lin_api_token_cleanup_task",
          webhook_secret: "whsec_cleanup_task"
        },
        name: "Cleanup Task Project 8708",
        github_repo: "org/cleanup-task-8708",
        github_installation_id: 8708,
        linear_team_key: "P8708",
        default_branch: "main",
        clone_path: "/tmp/repos/cleanup-task-8708",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_cleanup_task_8709",
              "identifier" => "TSK-8709",
              "title" => "Task 8709"
            }
          }
        }
      })
    end)

    {:ok, issue_8709} = Issues.create_issue(system_scope(), project, %{description: "Task 8709"})

    {:ok, task} = Pipeline.create_task(issue_8709, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :merged,
        worktree_name: "removed-worktree",
        worktree_path: "/tmp/rail-removed-worktree"
      })

    assert {:ok, %Task{}} = Pipeline.cleanup_task(task)
  end

  # Cleaning up twice is ordinary: two people can press it, and the second press
  # must not rewrite when the first one happened.
  test "a task already cleaned up keeps the time it was", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_twice", "identifier" => "CLN-2", "title" => "Task cleaned twice"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Task cleaned twice"})
    {:ok, task} = Pipeline.create_task(issue, :product)
    {:ok, task} = Pipeline.update_task(task, %{stage: :merged})

    assert {:ok, %Task{cleaned_up_at: %DateTime{} = first}} = Pipeline.cleanup_task(task)
    assert {:ok, %Task{cleaned_up_at: ^first}} = Pipeline.cleanup_task(Repo.reload!(task))
  end

  test "frees the task's worktree slot, and a new worktree would need setting up again", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_slot: 2, worktree_setup_at: DateTime.utc_now()})

    assert {:ok, %Task{worktree_slot: nil, worktree_setup_at: nil}} = Pipeline.cleanup_task(task)
  end
end
