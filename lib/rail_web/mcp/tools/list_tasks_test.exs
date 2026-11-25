defmodule RailWeb.Mcp.Tools.ListTasksTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
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
end
