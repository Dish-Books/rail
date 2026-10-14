defmodule Rail.Pipeline.Actions.SendPlanToLeadTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: extends the module.

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
            "issue" => %{"id" => "lin_send_plan_1", "identifier" => "SPL-1", "title" => "The plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "The raw ask."})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, _saved} = Pipeline.save_plan(task, %{title: "The ticket", description: "Its body.", plan: @plan})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: plan_role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_send_plan",
        started_at: DateTime.utc_now()
      })

    people =
      Map.new([owner: false, lead: true, teammate: false], fn {who, tech_lead} ->
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "gh_send_plan_#{who}",
            login: "#{who}-send_plan",
            email: "#{who}-send_plan@example.com"
          })

        {:ok, user} = Users.update_user(system_scope(), user, %{tech_lead: tech_lead, project_ids: [project.id]})
        {who, user_scope(user: user)}
      end)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [owner_user_id: people.owner.user.id])
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    Map.merge(people, %{task: task, run: run})
  end

  test "the owner's send marks the plan ready as them, starts nothing and tells every page", %{
    task: %Task{id: task_id} = task,
    run: run,
    owner: %{user: %{id: owner_id}} = owner
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    assert {:ok, %Round{number: 1, ready_at: %DateTime{}, ready_by_id: ^owner_id, approved_at: nil}} =
             Pipeline.send_plan_to_lead(owner, run)

    assert %Task{stage: :plan} = Repo.reload!(task)
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a second send keeps who sent it first and when", %{task: task, run: run, owner: %{user: %{id: owner_id}} = owner} do
    {:ok, %Round{ready_at: first_at}} = Pipeline.send_plan_to_lead(owner, run)

    assert {:ok, %Round{ready_at: ^first_at, ready_by_id: ^owner_id}} = Pipeline.send_plan_to_lead(system_scope(), run)
    assert %Round{ready_at: ^first_at} = Pipeline.read_plan(task)
  end

  test "saving the plan again takes it back out of the leads' queue", %{task: task, run: run, owner: owner} do
    {:ok, _sent} = Pipeline.send_plan_to_lead(owner, run)
    {:ok, _saved} = Pipeline.save_plan(task, %{description: "Its body, revised."})

    assert %Round{ready_at: nil, ready_by_id: nil} = Pipeline.read_plan(task)
  end

  test "only the task's owner sends its plan, and only in a project they can open", %{
    task: task,
    run: run,
    lead: lead,
    teammate: teammate
  } do
    assert {:error, :not_owner} = Pipeline.send_plan_to_lead(lead, run)
    assert {:error, :not_owner} = Pipeline.send_plan_to_lead(teammate, run)
    assert {:error, :not_found} = Pipeline.send_plan_to_lead(user_scope(project_ids: []), run)
    assert %Round{ready_at: nil} = Pipeline.read_plan(task)
  end

  test "a plan with no implementation plan yet, one still being written, or one past Plan is not sent", %{
    task: task,
    run: run,
    owner: owner
  } do
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])
    assert {:error, :no_plan} = Pipeline.send_plan_to_lead(owner, run)

    {:ok, _working} = Pipeline.update_run(run, %{status: :running})
    assert {:error, :stage_running} = Pipeline.send_plan_to_lead(owner, run)

    {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.send_plan_to_lead(owner, run)
  end
end
