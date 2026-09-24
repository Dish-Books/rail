defmodule Rail.Pipeline.Actions.ListRunsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :product)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_list_runs_1", "identifier" => "LST-1", "title" => "List Runs Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Runs Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    %{project: project, role: role, task: task, run: run}
  end

  test "leaves out runs on cleaned-up tasks unless asked", %{project: project, task: task, run: %Run{id: run_id}} do
    {:ok, _cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    assert [] = Pipeline.list_runs(project_id: project.id)
    assert [%Run{id: ^run_id}] = Pipeline.list_runs(project_id: project.id, include_cleaned_up: true)
  end

  test "lists every run, preloaded as asked", %{run: %Run{id: run_id}} do
    assert [%Run{id: ^run_id, task: %Task{}}] = Pipeline.list_runs(preload: [:task])
  end

  test "lists only the runs of one project", %{project: project, run: %Run{id: run_id}} do
    assert [%Run{id: ^run_id}] = Pipeline.list_runs(project_id: project.id)
    assert [] = Pipeline.list_runs(project_id: "prj_other")
  end

  test "filters runs to the ones on issues a user owns", %{project: project, role: role, run: %Run{id: unowned_id}} do
    {:ok, %{id: user_id}} =
      Users.register_oauth_user(%{github_id: "gh_list_runs_owner", login: "list_runs_owner", email: "lro@example.com"})

    {:ok, %{id: rival_id}} =
      Users.register_oauth_user(%{github_id: "gh_list_runs_rival", login: "list_runs_rival", email: "lrr@example.com"})

    [%Run{id: mine_id}, %Run{id: theirs_id}] =
      for {owner_id, n} <- [{user_id, 2}, {rival_id, 3}] do
        Req.Test.expect(Rail.Linear, fn conn ->
          Req.Test.json(conn, %{
            "data" => %{
              "issueCreate" => %{
                "success" => true,
                "issue" => %{"id" => "lin_list_runs_#{n}", "identifier" => "LST-#{n}", "title" => "List Runs #{n}"}
              }
            }
          })
        end)

        {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "List Runs #{n}"})
        {:ok, issue} = Issues.update_issue(issue, %{owner_user_id: owner_id})
        {:ok, task} = Pipeline.create_task(issue, :product)

        {:ok, run} =
          Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

        run
      end

    assert [%Run{id: ^mine_id}] = Pipeline.list_runs(project_id: project.id, owner_user_id: user_id)

    assert [project_id: project.id] |> Pipeline.list_runs() |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([unowned_id, mine_id, theirs_id])
  end
end
