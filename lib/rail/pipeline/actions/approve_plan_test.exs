defmodule Rail.Pipeline.Actions.ApprovePlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  # The smallest plan the structure allows: no diagrams, so Approach says why, and no Program design.
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
    roles =
      Map.new([:plan, :engineer], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_approve_plan_1", "identifier" => "APP-1", "title" => "Approve Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "The raw ask."})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Approved title", description: "The approved ticket body."})
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_approve_plan",
        started_at: DateTime.utc_now()
      })

    design_dir = Path.join(task.scratch_path, "design")

    # Three options saved, the second picked, and the plan saved again for it.
    picked = fn ->
      File.mkdir_p!(design_dir)

      for key <- ["cards", "table", "timeline"] do
        File.write!(Path.join(design_dir, "#{key}.html"), "<h1>#{key}</h1>")
        File.write!(Path.join(design_dir, "#{key}.png"), "png bytes")
        title = String.capitalize(key)
        {:ok, _option} = Pipeline.save_design_option(task, %{key: key, title: title, summary: "#{title} summary."})
      end

      File.write!(
        Path.join(design_dir, "manifest.json"),
        ~s({"options": [{"key": "table", "title": "Table", "summary": "Dense rows."}]})
      )

      File.rm!(Path.join(design_dir, "cards.html"))
      File.write!(Path.join(design_dir, "picked"), "table")
    end

    uploaded = fn ->
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{
              "success" => true,
              "uploadFile" => %{
                "uploadUrl" => "https://uploads.linear.app/put/app-1",
                "assetUrl" => "https://uploads.linear.app/assets/app-1-table.png",
                "headers" => []
              }
            }
          }
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        assert {:ok, "png bytes", conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, "")
      end)
    end

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    %{task: task, roles: roles, run: run, design_dir: design_dir, picked: picked, uploaded: uploaded}
  end

  test "with no options it publishes the ticket alone, records the plan and moves the task to Engineer", %{
    task: task,
    roles: roles,
    run: run
  } do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    assert %Task{stage: :engineer} = Repo.reload!(task)
    assert %Run{status: :running} = Repo.get_by(Run, task_id: task.id, role_id: roles[:engineer].id)
    assert %Issue{title: "Approved title", description: "The approved ticket body."} = Repo.get!(Issue, task.issue_id)

    assert %ImplementationPlan{content: @plan} =
             Repo.get_by(ImplementationPlan, task_id: task.id)
  end

  test "approving again after a return to Plan replaces the plan Engineer builds from", %{
    task: task,
    roles: roles,
    run: run
  } do
    {:ok, _run} = Pipeline.approve_plan(system_scope(), run)
    Repo.update_all(from(r in Run, where: r.role_id == ^roles[:engineer].id), set: [status: :finished])
    %ImplementationPlan{id: id, captured_at: first_at} = Repo.get_by(ImplementationPlan, task_id: task.id)
    {:ok, task} = Pipeline.update_task(Repo.reload!(task), %{stage: :plan})
    second = String.replace(@plan, "Extend the module.", "The second agreement.")
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: second})

    assert {:ok, %Run{}} = Pipeline.approve_plan(system_scope(), run)

    assert %ImplementationPlan{
             id: ^id,
             content: ^second,
             captured_at: second_at
           } =
             Repo.get_by(ImplementationPlan, task_id: task.id)

    assert DateTime.after?(second_at, first_at)
  end

  test "with a pick it adds the picked design's section and screenshot to the ticket in one write", %{
    task: task,
    run: run,
    picked: picked,
    uploaded: uploaded
  } do
    picked.()
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "table"})
    uploaded.()

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    description =
      "The approved ticket body.\n\n## Design: Table\n\nDense rows.\n\n![Table](https://uploads.linear.app/assets/app-1-table.png)"

    assert %Issue{title: "Approved title", description: ^description} = Repo.get!(Issue, task.issue_id)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a second approval gets the invalid-stage error and publishes nothing again", %{task: task, run: run} do
    assert {:ok, _approved} = Pipeline.approve_plan(system_scope(), run)
    {:ok, _issue} = Issues.update_issue(Repo.get!(Issue, task.issue_id), %{description: "Edited in Linear since."})

    assert {:error, {:invalid_stage, :engineer}} = Pipeline.approve_plan(system_scope(), run)
    assert %Issue{description: "Edited in Linear since."} = Repo.get!(Issue, task.issue_id)
  end

  test "is refused without a ticket, or without a plan", %{task: task, run: run} do
    File.rm!(Path.join([task.scratch_path, "plans", "APP-1.md"]))
    assert {:error, :no_plan} = Pipeline.approve_plan(system_scope(), run)

    File.rm!(Path.join([task.scratch_path, "tickets", "APP-1.md"]))
    assert {:error, :no_ticket} = Pipeline.approve_plan(system_scope(), run)

    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "with options and no pick it is refused", %{task: task, run: run, picked: picked, design_dir: dir} do
    picked.()
    File.rm!(Path.join(dir, "picked"))

    assert {:error, :nothing_picked} = Pipeline.approve_plan(system_scope(), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "a plan saved before the pick, or for another option, is refused", %{task: task, run: run, picked: picked} do
    picked.()
    assert {:error, :plan_not_for_pick} = Pipeline.approve_plan(system_scope(), run)

    File.write!(Path.join([task.scratch_path, "plans", "APP-1.design.json"]), ~s({"key": "cards", "title": "Cards"}))
    assert {:error, :plan_not_for_pick} = Pipeline.approve_plan(system_scope(), run)
  end

  test "a stale or missing screenshot is not published", %{task: task, run: run, picked: picked, design_dir: dir} do
    picked.()
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "table"})

    File.touch!(Path.join(dir, "table.html"), System.os_time(:second) + 60)
    assert {:error, :stale_screenshot} = Pipeline.approve_plan(system_scope(), run)

    File.rm!(Path.join(dir, "table.png"))
    assert {:error, :screenshot_missing} = Pipeline.approve_plan(system_scope(), run)

    assert %Issue{title: "Approve Plan"} = Repo.get!(Issue, task.issue_id)
  end

  test "an upload Linear refuses leaves the task at Plan with nothing recorded", %{task: task, run: run, picked: picked} do
    picked.()
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "table"})
    Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"fileUpload" => %{"success" => false}}}))

    assert {:error, _reason} = Pipeline.approve_plan(system_scope(), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
    refute Repo.get_by(ImplementationPlan, task_id: task.id)
    assert %Run{stage_outcome: :done} = Repo.reload!(run)
  end

  test "an empty manifest is no screen, and an issue write that fails leaves the task at Plan", %{
    task: task,
    run: run,
    design_dir: dir
  } do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": []}))
    expect(Issues, :update_issue, fn _issue, %{title: "Approved title"} -> {:error, :linear_down} end)

    assert {:error, :linear_down} = Pipeline.approve_plan(system_scope(), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
    refute Repo.get_by(ImplementationPlan, task_id: task.id)
  end

  test "nothing is approved while Plan is still working", %{run: run} do
    {:ok, working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

    assert {:error, :stage_running} = Pipeline.approve_plan(system_scope(), working)
  end

  test "a user without the project cannot approve it", %{task: task, run: run} do
    assert {:error, :not_found} = Pipeline.approve_plan(user_scope(project_ids: []), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
  end
end
