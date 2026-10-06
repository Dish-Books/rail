defmodule Rail.Pipeline.Utils.PlanRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.PlanRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles

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
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_plan_finished_1", "identifier" => "PFN-1", "title" => "Plan Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Plan Finished"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    options = fn keys, built ->
      entries = for key <- keys, do: %{"key" => key, "title" => String.upcase(key)}
      File.write!(Path.join(design_dir, "manifest.json"), Jason.encode!(%{"options" => entries}))

      for key <- built do
        File.write!(Path.join(design_dir, "#{key}.html"), "<h1>#{key}</h1>")
        File.write!(Path.join(design_dir, "#{key}.png"), "png")
      end
    end

    ticket = fn -> {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Plan Finished", description: "Body."}) end
    plan = fn -> {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan}) end

    %{run: Repo.preload(run, [:task, :role]), options: options, ticket: ticket, plan: plan, design_dir: design_dir}
  end

  test "a turn that saved no ticket records that first", %{run: run, plan: plan} do
    plan.()
    assert %Run{error: "The Plan agent did not save a ticket."} = plan_run_finished(run, [])
  end

  test "options that are neither three nor picked record how many", %{run: run, ticket: ticket, options: options} do
    ticket.()
    options.(["a", "b"], ["a", "b"])

    assert %Run{error: "The Plan agent saved 2 design options. It needs 3, or a pick."} = plan_run_finished(run, [])
  end

  test "an option missing its page or screenshot is named", %{run: run, ticket: ticket, options: options, design_dir: dir} do
    ticket.()
    options.(["a", "b", "c"], ["a", "b", "c"])
    File.rm!(Path.join(dir, "c.png"))

    assert %Run{error: "Saved design options missing a page or screenshot: c."} = plan_run_finished(run, [])
  end

  test "a turn that saved no plan records that last", %{run: run, ticket: ticket, options: options} do
    ticket.()
    options.(["a", "b", "c"], ["a", "b", "c"])

    assert %Run{error: "The Plan agent did not save a plan."} = plan_run_finished(run, [])
  end

  test "a ticket and a plan finish clean with no options, with three, or with a pick", %{
    run: run,
    ticket: ticket,
    plan: plan,
    options: options,
    design_dir: dir
  } do
    ticket.()
    plan.()
    assert %Run{error: nil} = plan_run_finished(run, [])

    options.(["a", "b", "c"], ["a", "b", "c"])
    assert %Run{error: nil} = plan_run_finished(run, [])

    options.(["b"], [])
    File.write!(Path.join(dir, "picked"), "b")
    assert %Run{error: nil} = plan_run_finished(run, [])
  end
end
