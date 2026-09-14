defmodule Rail.Pipeline.Actions.ListTasksTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "List Tasks Project 7101",
        github_repo: "org/list-tasks-7101",
        github_installation_id: 7101,
        linear_workspace: %{
          name: "List Tasks Workspace",
          external_id: "lin_ws_list_tasks",
          token: "lin_api_token_list_tasks",
          webhook_secret: "whsec_list_tasks"
        },
        linear_team_key: "P7101",
        default_branch: "main",
        clone_path: "/tmp/repos/list-tasks-7101",
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
              "id" => "lin_list_tasks_1",
              "identifier" => "LTS-1",
              "title" => "List Tasks Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "List Tasks Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "leaves out cleaned-up tasks unless asked", %{project: project, task: %Task{id: task_id} = task} do
    {:ok, _cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    assert [] = Pipeline.list_tasks(project_id: project.id)
    assert [%Task{id: ^task_id}] = Pipeline.list_tasks(project_id: project.id, include_cleaned_up: true)
  end

  test "filters tasks by stage", %{project: project, task: task} do
    {:ok, %Task{id: prod_id}} =
      Pipeline.update_task(task, %{
        stage: :product
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_list_tasks_7103",
              "identifier" => "TSK-7103",
              "title" => "Task 7103"
            }
          }
        }
      })
    end)

    {:ok, issue_7103} = Issues.create_issue(system_scope(), project, %{description: "Task 7103"})

    {:ok, %Task{id: eng_q_id}} = Pipeline.create_task(issue_7103, :product)

    {:ok, %Task{id: eng_q_id}} =
      Pipeline.update_task(Repo.get!(Task, eng_q_id), %{
        stage: :engineer
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_list_tasks_7104",
              "identifier" => "TSK-7104",
              "title" => "Task 7104"
            }
          }
        }
      })
    end)

    {:ok, issue_7104} = Issues.create_issue(system_scope(), project, %{description: "Task 7104"})

    {:ok, t_eng_other} = Pipeline.create_task(issue_7104, :product)

    {:ok, %Task{id: eng_other_id}} = Pipeline.update_task(t_eng_other, %{stage: :engineer})

    assert [%Task{id: ^prod_id}] = Pipeline.list_tasks(project_id: project.id, stage: :product)

    engineer_ids = [project_id: project.id, stage: :engineer] |> Pipeline.list_tasks() |> Enum.map(& &1.id) |> Enum.sort()
    assert engineer_ids == Enum.sort([eng_q_id, eng_other_id])
  end

  test "supports custom order_by", %{project: project, task: task} do
    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id), set: [title: "Alpha"])

    {:ok, %Task{id: id1}} =
      Pipeline.update_task(task, %{})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_list_tasks_7105",
              "identifier" => "TSK-7105",
              "title" => "Beta"
            }
          }
        }
      })
    end)

    {:ok, issue_7105} = Issues.create_issue(system_scope(), project, %{description: "Beta"})

    {:ok, %Task{id: id2}} = Pipeline.create_task(issue_7105, :product)

    assert [%Task{id: ^id2}, %Task{id: ^id1}] =
             Pipeline.list_tasks(project_id: project.id, order_by: [desc: :inserted_at])
  end

  test "lists tasks across all projects when project_id is nil", %{task: task} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, _p1} =
      Projects.create_project(system_scope(), %{
        linear_workspace: %{
          name: "List Tasks Workspace",
          external_id: "lin_ws_list_tasks_x4",
          token: "lin_api_token_list_tasks",
          webhook_secret: "whsec_list_tasks"
        },
        name: "List Tasks Project 7107",
        github_repo: "org/list-tasks-7107",
        github_installation_id: 7107,
        linear_team_key: "P7107",
        default_branch: "main",
        clone_path: "/tmp/repos/list-tasks-7107",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, p2} =
      Projects.create_project(system_scope(), %{
        linear_workspace: %{
          name: "List Tasks Workspace",
          external_id: "lin_ws_list_tasks_x5",
          token: "lin_api_token_list_tasks",
          webhook_secret: "whsec_list_tasks"
        },
        name: "List Tasks Project 7108",
        github_repo: "org/list-tasks-7108",
        github_installation_id: 7108,
        linear_team_key: "P7108",
        default_branch: "main",
        clone_path: "/tmp/repos/list-tasks-7108",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id), set: [title: "P1 Task"])

    {:ok, %Task{id: id1}} =
      Pipeline.update_task(task, %{})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_list_tasks_7106",
              "identifier" => "TSK-7106",
              "title" => "P2 Task"
            }
          }
        }
      })
    end)

    {:ok, issue_7106} = Issues.create_issue(system_scope(), p2, %{description: "P2 Task"})

    {:ok, %Task{id: id2}} = Pipeline.create_task(issue_7106, :product)

    all_tasks_system = Pipeline.list_tasks()
    all_ids_system = Enum.map(all_tasks_system, & &1.id)
    assert id1 in all_ids_system
    assert id2 in all_ids_system

    all_tasks_user = Pipeline.list_tasks()
    all_ids_user = Enum.map(all_tasks_user, & &1.id)
    assert id1 in all_ids_user
    assert id2 in all_ids_user
  end

  test "supports preload option", %{project: %Project{id: expected_project_id}, task: task} do
    Repo.update_all(from(i in Issue, where: i.id == ^Repo.get!(Task, task.id).issue_id), set: [title: "Preload Task"])

    {:ok, %Task{id: id1}} =
      Pipeline.update_task(task, %{})

    assert [%Task{id: ^id1, project: %Project{id: ^expected_project_id}}] =
             Pipeline.list_tasks(project_id: expected_project_id, preload: [:project])
  end
end
