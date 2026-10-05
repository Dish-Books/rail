defmodule Rail.Pipeline.Actions.StartDesignRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :design)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_design_1",
              "identifier" => "SDR-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :design)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run}
  end

  test "briefs the designer on the three options it builds in scratch and saves one at a time", %{
    task: task,
    run: run
  } do
    design_dir = Path.join(task.scratch_path, "design")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "exactly three distinct design options"
      assert prompt =~ "Save each option with the `save_design_option` tool as soon as its page and screenshot exist"
      refute prompt =~ "<<'MANIFEST'"
      refute prompt =~ "manifest.json"
      assert prompt =~ "--window-size=1920,1170 --screenshot=#{design_dir}/<key>.png file://#{design_dir}/<key>.html"
      assert prompt =~ "Rail records the pick in #{design_dir}/picked and deletes the options not picked"
      assert prompt =~ ~s(<ticket title="Invoice filters">\nFilter invoices by vendor.\n</ticket>)

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_design_run(run)
    assert File.dir?(design_dir)
  end

  test "the brief carries the rules retrieved with the ticket", %{project: project, run: run} do
    stub_vertex(%{"Filter invoices" => vector([1.0])})

    learning(project, %{rule: "Amber only means a person is waited on", kind: :design, roles: [:design]},
      embedding: [1.0]
    )

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "- Design: Amber only means a person is waited on"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_design_run(run)
    assert_received {:embedded, "Invoice filters\n\nFilter invoices by vendor.", "RETRIEVAL_QUERY"}
  end
end
