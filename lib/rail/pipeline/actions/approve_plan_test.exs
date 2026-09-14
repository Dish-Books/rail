defmodule Rail.Pipeline.Actions.ApprovePlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Approve Plan Project",
        github_repo: "org/approve-plan",
        github_installation_id: 47_006,
        linear_workspace: %{
          name: "Approve Plan Workspace",
          external_id: "lin_ws_approve_plan",
          token: "lin_api_token_approve_plan",
          webhook_secret: "whsec_approve_plan"
        },
        linear_team_key: "APP",
        default_branch: "main",
        clone_path: "/tmp/repos/approve-plan",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    roles =
      Map.new([:architect, :engineer], fn stage ->
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
              "id" => "lin_approve_plan_1",
              "identifier" => "APP-1",
              "title" => "Approve Plan",
              "description" => "The approved ticket body."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "The approved ticket body."})
    {:ok, task} = Pipeline.create_task(issue, :architect)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    plans_dir = Path.join(task.scratch_path, "plans")
    File.mkdir_p!(plans_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    plan_path = Path.join(plans_dir, "APP-1.md")
    File.write!(plan_path, "## Implementation plan\n\n### Approach\nExtend the existing module.\n")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_approve_plan",
        started_at: DateTime.utc_now()
      })

    %{task: task, roles: roles, run: run, plan_path: plan_path}
  end

  test "records the plan and hands the task to the engineer", %{task: task, roles: roles, run: run} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(run)

    assert %Task{stage: :engineer} = Repo.reload!(task)
    assert Repo.get_by(Run, task_id: task.id, role_id: roles[:engineer].id)

    assert %ImplementationPlan{content: content, captured_at: %DateTime{}} =
             Repo.get_by(ImplementationPlan, task_id: task.id)

    assert content =~ "Extend the existing module."
  end

  test "a second pass replaces what the first plan said rather than leaving two", %{task: task, run: run} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "What the first pass said.",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, _approved} = Pipeline.approve_plan(run)

    assert [%ImplementationPlan{content: content}] = Repo.all(ImplementationPlan)
    assert content =~ "Extend the existing module."
  end

  test "an unwritten plan is not approved", %{task: task, run: run, plan_path: path} do
    File.rm!(path)

    assert {:error, :no_plan} = Pipeline.approve_plan(run)
    assert %Task{stage: :architect} = Repo.reload!(task)
    assert Repo.get_by(ImplementationPlan, task_id: task.id) == nil
  end

  test "nothing is approved while the architect is still working", %{run: run} do
    {:ok, working} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.approve_plan(working)
  end

  test "a task past architect has nothing left to approve", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:error, {:invalid_stage, :engineer}} = Pipeline.approve_plan(run)
  end
end
