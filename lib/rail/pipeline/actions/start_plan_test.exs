defmodule Rail.Pipeline.Actions.StartPlanTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  ### Decisions

  - Decision: one module changes.

  ### Changes

  #### `lib/rail.ex`

  Extends the module.

  ### Acceptance criteria

  - 1: `lib/rail.ex`

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup %{project: project} do
    {:ok, plan_role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_start_plan_1", "identifier" => "STP-1", "title" => "The plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "The raw ask."})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    # Starting the work only queues the engineer, so the worktree is a plain directory nothing asks git about.
    worktree_path = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree_path)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    {:ok, _saved} = Pipeline.save_plan(task, %{title: "The ticket", description: "Its body.", plan: @plan})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: plan_role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_start_plan",
        started_at: DateTime.utc_now()
      })

    people =
      Map.new([owner: false, lead: true, teammate: false], fn {who, tech_lead} ->
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "gh_start_plan_#{who}",
            login: "#{who}-start_plan",
            email: "#{who}-start_plan@example.com"
          })

        {:ok, user} = Users.update_user(system_scope(), user, %{tech_lead: tech_lead, project_ids: [project.id]})
        {who, user_scope(user: user)}
      end)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [owner_user_id: people.owner.user.id])
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    Map.merge(people, %{task: task, run: run})
  end

  test "the owner starts the work without approval: the ticket is published, the engineer queued and the plan left for a lead",
       %{task: %Task{id: task_id} = task, run: run, owner: %{user: %{id: owner_id}} = owner} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.start_plan(owner, run)

    assert %Task{stage: :engineer} = Repo.reload!(task)
    assert %Issue{title: "The ticket", description: "Its body."} = Repo.get!(Issue, task.issue_id)
    assert_enqueued(worker: StartEngineer, args: %{task_id: task_id})
    assert %Round{ready_at: %DateTime{}, ready_by_id: ^owner_id, approved_at: nil} = Pipeline.read_plan(task)
    assert [%Task{id: ^task_id}] = Pipeline.list_tasks(project_id: task.project_id, plan_ready: true)
  end

  test "a plan already sent keeps who sent it and when", %{task: task, run: run, owner: owner} do
    {:ok, %Round{ready_at: sent_at}} = Pipeline.send_plan_to_lead(owner, run)

    assert {:ok, %Run{}} = Pipeline.start_plan(owner, run)
    assert %Round{ready_at: ^sent_at, approved_at: nil} = Pipeline.read_plan(task)
  end

  test "nobody but the owner starts it, a tech lead included, and a second start finds the task moved on", %{
    task: task,
    run: run,
    owner: owner,
    lead: lead,
    teammate: teammate
  } do
    assert {:error, :not_owner} = Pipeline.start_plan(lead, run)
    assert {:error, :not_owner} = Pipeline.start_plan(teammate, run)
    assert %Task{stage: :plan} = Repo.reload!(task)

    assert {:ok, %Run{}} = Pipeline.start_plan(system_scope(), run)
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.start_plan(owner, run)
  end
end
