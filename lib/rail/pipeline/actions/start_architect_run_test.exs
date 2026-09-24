defmodule Rail.Pipeline.Actions.StartArchitectRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :architect)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_architect_1",
              "identifier" => "SAR-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :architect)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run}
  end

  test "briefs the architect on the one plan file it writes into scratch", %{
    task: task,
    run: run
  } do
    plans_dir = Path.join(task.scratch_path, "plans")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "You are planning it, not building it"
      assert prompt =~ "cat > #{plans_dir}/SAR-1.md <<'PLAN'"
      assert prompt =~ "Keep the `## Implementation plan` heading on the first line."
      assert prompt =~ "The ticket itself is not yours to write."
      assert prompt =~ "Ask everything at once."
      assert prompt =~ ~s(<ticket title="Invoice filters">\nFilter invoices by vendor.\n</ticket>)

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_architect_run(run)
    assert File.dir?(plans_dir)
  end

  test "points the architect at the page the human approved, not just its screenshot", %{
    task: task,
    run: run
  } do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "cards", "title": "Cards"}, {"key": "table", "title": "Table"}]})
    )

    File.write!(Path.join(design_dir, "cards.html"), "<h1>Cards</h1>")
    File.write!(Path.join(design_dir, "picked"), "cards")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ ~s(The human approved the design "Cards".)
      assert prompt =~ "The page is #{design_dir}/cards.html"
      assert prompt =~ "its screenshot is #{design_dir}/cards.png"
      refute prompt =~ "table.html"

      # The design is read against the ticket, so it comes after it.
      assert :binary.match(prompt, "</ticket>") < :binary.match(prompt, "approved the design")

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_architect_run(run)
  end

  # Product can approve straight past design, which leaves nothing on disk to read.
  test "says nothing about a design when there is none", %{task: task, run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"
      refute prompt =~ Path.join(task.scratch_path, "design")

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_architect_run(run)
  end

  # A design nobody picked is not the approved one, so it is not the plan's spec.
  test "says nothing about options the human never picked between", %{task: task, run: run} do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "cards", "title": "Cards"}]})
    )

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_architect_run(run)
  end
end
