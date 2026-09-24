defmodule Rail.Pipeline.Actions.StartEngineerRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_engineer_1",
              "identifier" => "SEN-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{project: project, task: task, run: run}
  end

  test "briefs the engineer on the plan it builds and the file that says it is done", %{task: task, run: run} do
    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "### Approach\nExtend the invoices module.",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    commits_dir = Path.join(task.scratch_path, "commits")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Build the approved plan below."
      assert prompt =~ "Extend the invoices module."
      assert prompt =~ "cat > #{commits_dir}/SEN-1.md <<'MSG'"
      assert prompt =~ "Never run git."
      assert prompt =~ "Your worktree is #{task.worktree_path}"
      assert prompt =~ "The branch #{task.worktree_name} is already checked out"
      assert prompt =~ "its base is main on remote `origin`"
      assert prompt =~ "Ask everything at once."
      assert prompt =~ "Run every command in the foreground and wait for it"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
    assert File.dir?(commits_dir)
  end

  # Product can approve straight past design and architect, which leaves no plan.
  test "says the ticket is the whole specification when there is no plan", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "There is no implementation plan for this ticket"
      assert prompt =~ "Filter invoices by vendor."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  test "carries the design page the human approved, not just a path to it", %{task: task, run: run} do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "cards", "title": "Cards"}, {"key": "table", "title": "Table"}]})
    )

    File.write!(Path.join(design_dir, "cards.html"), "<h1>Invoices</h1>")
    File.write!(Path.join(design_dir, "table.html"), "<table>Rejected</table>")
    File.write!(Path.join(design_dir, "picked"), "cards")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ ~s(The human approved the design "Cards")
      assert prompt =~ ~s(<design title="Cards">\n<h1>Invoices</h1>\n</design>)
      assert prompt =~ "#{design_dir}/cards.html"
      refute prompt =~ "Rejected"

      # The design is read against the ticket, so it comes before it.
      assert :binary.match(prompt, "</design>") < :binary.match(prompt, "The ticket it was planned from")

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  # Product can approve straight past design, which leaves nothing on disk to read.
  test "says nothing about a design when there is none", %{task: task, run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"
      refute prompt =~ Path.join(task.scratch_path, "design")

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  # A design nobody picked is not the approved one, so it is not what gets built.
  test "says nothing about options the human never picked between", %{task: task, run: run} do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(Path.join(design_dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    File.write!(Path.join(design_dir, "cards.html"), "<h1>Invoices</h1>")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  # An option whose page was never written has nothing to hand over.
  test "says nothing about a design whose page is missing", %{task: task, run: run} do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(Path.join(design_dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    File.write!(Path.join(design_dir, "picked"), "cards")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  test "carries every comment on the issue", %{task: task, run: run} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "lin_comment_1",
              "body" => "Use the existing filter helper.",
              "createdAt" => "2026-09-14T10:00:00.000Z",
              "issue" => %{"id" => "lin_start_engineer_1"}
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.get_issue(task.issue_id)
    {:ok, _comment} = Issues.comment(system_scope(), issue, %{body: "Use the existing filter helper."})

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Use the existing filter helper."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  test "tells the engineer CI runs on its commit, and that failures come back to it", %{project: project, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Rail runs `mise run ci` on it before anything else sees it"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_engineer_run(run)
  end
end
