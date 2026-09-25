defmodule Rail.Pipeline.Actions.ApproveProductPlanTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :demo], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_approve_plan_1",
              "identifier" => "APV-1",
              "title" => "Approve Plan Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Approve Plan Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, task: task, roles: roles}
  end

  setup %{task: task, roles: roles} do
    scratch = Path.join(System.tmp_dir!(), "approve_plan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch, "tickets"))
    on_exit(fn -> File.rm_rf(scratch) end)

    File.write!(
      Path.join([scratch, "tickets", "APV-1.md"]),
      "---\ntitle: The approved ticket\n---\n\nWhat the product agent wrote.\n"
    )

    {:ok, task} =
      Pipeline.update_task(task, %{scratch_path: scratch, worktree_path: create_temp_git_repo()})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    %{task: task, scratch: scratch, run: Repo.preload(run, task: [:issue, :runs])}
  end

  test "publishes the ticket the product run wrote and hands it to design", %{
    task: task,
    run: run,
    roles: roles
  } do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_product_plan(run)

    assert %Task{stage: :design} = Repo.reload!(task)

    assert %Issue{title: "The approved ticket", description: "What the product agent wrote."} =
             Repo.get!(Issue, task.issue_id)

    assert Repo.get_by(Run, task_id: task.id, role_id: roles[:design].id)
  end

  test "moves the Linear ticket to ready for dev", %{task: task, run: run} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{}} = Pipeline.approve_product_plan(run)

    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: task.issue_id, state: "todo"})
  end

  test "skipping designs hands the ticket straight to the architect", %{task: task, run: run, roles: roles} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{}} = Pipeline.approve_product_plan(run, skip_design: true)

    assert %Task{stage: :architect} = Repo.reload!(task)
    assert Repo.get_by(Run, task_id: task.id, role_id: roles[:architect].id)
  end

  test "a run that finished cleanly is approved, and only once", %{task: task, run: run} do
    # RunFinished latches a clean product run done; that is the run waiting on a human.
    {:ok, finished} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{}} = Pipeline.approve_product_plan(Repo.preload(finished, task: [:issue, :runs]))

    assert {:error, {:invalid_stage, :design}} =
             Pipeline.approve_product_plan(Repo.preload(finished, [task: [:issue, :runs]], force: true))
  end

  test "nothing is approved while something on the task is still working", %{task: task, run: run, roles: roles} do
    {:ok, _running} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :stage_running} =
             Pipeline.approve_product_plan(Repo.preload(run, [task: [:issue, :runs]], force: true))
  end

  test "a task past product has nothing left to approve", %{task: task, run: run} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:error, {:invalid_stage, :engineer}} =
             Pipeline.approve_product_plan(Repo.preload(run, [task: [:issue, :runs]], force: true))
  end

  test "a ticket the issue cannot take is not approved", %{task: task, scratch: scratch, run: run} do
    File.write!(Path.join([scratch, "tickets", "APV-1.md"]), "No title anywhere.\n")

    assert {:error, %Ecto.Changeset{}} = Pipeline.approve_product_plan(run)

    assert %Task{stage: :product} = Repo.reload!(task)
    assert %Run{stage_outcome: :in_progress} = Repo.reload!(run)
  end
end
