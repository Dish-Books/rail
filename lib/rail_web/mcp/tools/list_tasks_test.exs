defmodule RailWeb.Mcp.Tools.ListTasksTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Users

  setup do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    [local, hidden] =
      for name <- ["Listed", "Not granted"] do
        key = "MLT#{System.unique_integer([:positive])}"

        {:ok, project} =
          Projects.create_project(system_scope(), %{
            name: name,
            github_repo: "example/#{key}",
            github_installation_id: 1,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          })

        project
      end

    [user, teammate] =
      for name <- ["mlt", "mlt_mate"] do
        id = System.unique_integer([:positive])

        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "#{name}_#{id}",
            login: "#{name}_#{id}",
            name: name,
            email: "#{name}_#{id}@example.com"
          })

        {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
        user
      end

    %{local: local, hidden: hidden, user: user, teammate: teammate, scope: Rail.Scope.for_user(user)}
  end

  test "my tasks at Review come with their ticket, assignee, branch and pull request, and no one else's", %{
    local: local,
    hidden: hidden,
    user: %{login: login} = user,
    teammate: teammate,
    scope: scope
  } do
    {:ok, %{identifier: mine} = issue} =
      Issues.create_issue(system_scope(), local, %{title: "Mine at Review", owner_user_id: user.id})

    {:ok, %Task{worktree_name: branch} = task} = Pipeline.create_task(issue, :review)
    {:ok, _opened} = Pipeline.update_task(task, %{pr_number: 7, pr_url: "https://github.com/example/pull/7"})

    {:ok, implementing} =
      Issues.create_issue(system_scope(), local, %{title: "Mine at Implement", owner_user_id: user.id})

    {:ok, _task} = Pipeline.create_task(implementing, :engineer)
    {:ok, theirs} = Issues.create_issue(system_scope(), local, %{title: "Theirs", owner_user_id: teammate.id})
    {:ok, _task} = Pipeline.create_task(theirs, :review)
    {:ok, out_of_reach} = Issues.create_issue(system_scope(), hidden, %{title: "Hidden", owner_user_id: user.id})
    {:ok, _task} = Pipeline.create_task(out_of_reach, :review)

    assert {:ok,
            %{
              "tasks" => [
                %{
                  "identifier" => ^mine,
                  "title" => "Mine at Review",
                  "stage" => "Review",
                  "assignee" => ^login,
                  "branch" => ^branch,
                  "pull_request" => "https://github.com/example/pull/7",
                  "started_at" => "20" <> _started
                }
              ]
            }} = call_mcp_tool(scope, "list_tasks", %{"assignee" => "me", "stage" => "review"})

    assert {:ok, %{"tasks" => [%{"identifier" => ^mine}]}} =
             call_mcp_tool(scope, "list_tasks", %{"project" => local.key, "assignee" => login, "stage" => "review"})
  end

  test "lists the newest task first, a split with no branch, and refuses someone not in Rail", %{
    local: local,
    hidden: hidden,
    scope: scope
  } do
    {:ok, %{identifier: older} = first} = Issues.create_issue(system_scope(), local, %{title: "Older"})
    {:ok, split} = Pipeline.create_task(first, :plan)
    {:ok, _split} = Pipeline.update_task(split, %{stage: :split})
    {:ok, %{identifier: newer} = second} = Issues.create_issue(system_scope(), local, %{title: "Newer"})
    {:ok, %Task{worktree_name: branch}} = Pipeline.create_task(second, :engineer)

    assert {:ok,
            %{
              "tasks" => [
                %{"identifier" => ^newer, "stage" => "Implement", "branch" => ^branch, "assignee" => nil},
                %{"identifier" => ^older, "stage" => "Split", "branch" => nil}
              ]
            }} = call_mcp_tool(scope, "list_tasks", %{})

    assert {:error, "assignee nobody-here is no one in Rail."} =
             call_mcp_tool(scope, "list_tasks", %{"assignee" => "nobody-here"})

    assert {:error, "No project you can open has that key or name. Yours are: " <> _keys} =
             call_mcp_tool(scope, "list_tasks", %{"project" => hidden.key})
  end

  test "with waiting, only the tasks waiting on me, each wait with its kind, status, link, start and the same id twice",
       %{project: seeded, local: local, hidden: hidden, user: user, teammate: teammate, scope: scope} do
    now = DateTime.utc_now()

    for listed <- [local, hidden] do
      {:ok, [_first | _rest]} = Roles.copy_roles(system_scope(), listed.id, seeded.id)
    end

    {:ok, plan} = Roles.get_role(project_id: local.id, stage: :plan)
    {:ok, engineer} = Roles.get_role(project_id: local.id, stage: :engineer)

    {:ok, %{identifier: asking_key} = asking_issue} =
      Issues.create_issue(system_scope(), local, %{title: "Three questions", owner_user_id: user.id})

    {:ok, %Task{id: asking_id} = asking} = Pipeline.create_task(asking_issue, :plan)

    {:ok, %Run{id: asking_run_id} = asking_run} =
      Pipeline.create_run(%{task_id: asking.id, role_id: plan.id, status: :running, started_at: now})

    {:ok, %{asked: [_first, _second, %Question{id: newest_id}]}} =
      Pipeline.ask_questions(
        asking_run,
        for(p <- ["Which database?", "Behind a flag?", "Who signs off?"], do: %{"prompt" => p})
      )

    {:ok, _parked} = Pipeline.update_run(asking_run, %{status: :blocked_on_input})

    {:ok, %{identifier: planned_key} = planned_issue} =
      Issues.create_issue(system_scope(), local, %{title: "Plan to review", owner_user_id: user.id})

    {:ok, %Task{id: planned_id} = planned} = Pipeline.create_task(planned_issue, :plan)

    {:ok, %Run{id: planned_run_id, wait_started_at: planned_at}} =
      Pipeline.create_run(%{
        task_id: planned.id,
        role_id: plan.id,
        status: :finished,
        stage_outcome: :done,
        started_at: now
      })

    {:ok, %{identifier: failed_key} = failed_issue} =
      Issues.create_issue(system_scope(), local, %{title: "Engineer failed", owner_user_id: user.id})

    {:ok, %Task{id: failed_id} = failed} = Pipeline.create_task(failed_issue, :engineer)

    {:ok, %Run{id: failed_run_id, wait_started_at: failed_at}} =
      Pipeline.create_run(%{
        task_id: failed.id,
        role_id: engineer.id,
        status: :failed,
        error: "Exited with code 1",
        started_at: now
      })

    {:ok, %{identifier: working_key} = working_issue} =
      Issues.create_issue(system_scope(), local, %{title: "Still working", owner_user_id: user.id})

    {:ok, working} = Pipeline.create_task(working_issue, :engineer)

    {:ok, _running} =
      Pipeline.create_run(%{task_id: working.id, role_id: engineer.id, status: :running, started_at: now})

    {:ok, theirs_issue} =
      Issues.create_issue(system_scope(), local, %{title: "Theirs", owner_user_id: teammate.id})

    {:ok, theirs} = Pipeline.create_task(theirs_issue, :engineer)

    {:ok, _failed} =
      Pipeline.create_run(%{task_id: theirs.id, role_id: engineer.id, status: :failed, error: "Boom", started_at: now})

    {:ok, hidden_issue} = Issues.create_issue(system_scope(), hidden, %{title: "Hidden", owner_user_id: user.id})
    {:ok, hidden_task} = Pipeline.create_task(hidden_issue, :engineer)
    {:ok, hidden_engineer} = Roles.get_role(project_id: hidden.id, stage: :engineer)

    {:ok, _failed} =
      Pipeline.create_run(%{
        task_id: hidden_task.id,
        role_id: hidden_engineer.id,
        status: :failed,
        error: "Boom",
        started_at: now
      })

    questions_wait = "#{asking_run_id}:#{newest_id}"
    planned_wait = "#{planned_run_id}:#{DateTime.to_unix(planned_at, :microsecond)}"
    failed_wait = "#{failed_run_id}:#{DateTime.to_unix(failed_at, :microsecond)}"
    asking_url = RailWeb.Endpoint.url() <> "/tasks/#{asking_id}"
    planned_url = RailWeb.Endpoint.url() <> "/tasks/#{planned_id}"
    failed_url = RailWeb.Endpoint.url() <> "/tasks/#{failed_id}"

    for _call <- 1..2 do
      assert {:ok,
              %{
                "tasks" => [
                  %{
                    "identifier" => ^failed_key,
                    "waiting" => %{
                      "id" => ^failed_wait,
                      "kind" => "failed",
                      "summary" => "Implement failed",
                      "url" => ^failed_url,
                      "since" => "20" <> _failed_since
                    }
                  },
                  %{
                    "identifier" => ^planned_key,
                    "waiting" => %{
                      "id" => ^planned_wait,
                      "kind" => "review",
                      "summary" => "Review the plan",
                      "url" => ^planned_url,
                      "since" => "20" <> _planned_since
                    }
                  },
                  %{
                    "identifier" => ^asking_key,
                    "waiting" => %{
                      "id" => ^questions_wait,
                      "kind" => "questions",
                      "summary" => "Plan needs an answer",
                      "url" => ^asking_url,
                      "since" => "20" <> _asked_since
                    }
                  }
                ]
              }} = call_mcp_tool(scope, "list_tasks", %{"waiting" => true, "assignee" => "me"})
    end

    assert {:ok, %{"tasks" => [%{"identifier" => ^working_key, "waiting" => nil} | _rest]}} =
             call_mcp_tool(scope, "list_tasks", %{"assignee" => "me"})
  end

  test "with waiting and nothing waiting on me, the list is empty", %{local: local, user: user, scope: scope} do
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Not started", owner_user_id: user.id})
    {:ok, _task} = Pipeline.create_task(issue, :engineer)

    assert {:ok, %{"tasks" => []}} = call_mcp_tool(scope, "list_tasks", %{"waiting" => true, "assignee" => "me"})
  end
end
