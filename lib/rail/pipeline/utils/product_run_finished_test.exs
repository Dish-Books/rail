defmodule Rail.Pipeline.Utils.ProductRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ProductRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles

  setup %{project: project} do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :demo], fn stage ->
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
              "id" => "lin_settle_product_1",
              "identifier" => "S14601-1",
              "title" => "Settle Product Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Settle Product Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)
    tickets_dir = Path.join(task.scratch_path, "tickets")
    File.mkdir_p!(tickets_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    ticket_path = Path.join(tickets_dir, "S14601-1.md")
    File.write!(ticket_path, "---\ntitle: Settle Product Issue\n---\n\nThe ticket body.\n")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, [:task, :role])

    %{backend: backend, project: project, issue: issue, task: task, roles: roles, run: run, ticket_path: ticket_path}
  end

  test "leaves the task where it is: a human approves the ticket", %{task: task, run: run} do
    assert %Run{error: nil} = product_run_finished(run, [])
    assert %Task{stage: :product} = Repo.get!(Task, task.id)
  end

  test "a run that exited without a ticket records that rather than parking a human in front of nothing", %{
    task: task,
    run: run,
    ticket_path: path
  } do
    File.rm!(path)

    assert %Run{error: "The product agent did not write tickets/S14601-1.md."} = product_run_finished(run, [])
    assert %Task{stage: :product} = Repo.get!(Task, task.id)
  end

  test "a ticket that is only whitespace is no ticket", %{run: run, ticket_path: path} do
    File.write!(path, "\n  \n")

    assert %Run{error: "The product agent did not write tickets/S14601-1.md."} =
             product_run_finished(run, [])
  end
end
