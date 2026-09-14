defmodule Rail.Pipeline.Actions.StartDesignRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
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
        name: "Start Design Project",
        github_repo: "org/start-design",
        github_installation_id: 47_001,
        linear_workspace: %{
          name: "Start Design Workspace",
          external_id: "lin_ws_start_design",
          token: "lin_api_token_start_design",
          webhook_secret: "whsec_start_design"
        },
        linear_team_key: "SDR",
        default_branch: "main",
        clone_path: "/tmp/repos/start-design",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, _role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :design,
        name: "design role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the design agent."
      })

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

  test "briefs the designer on the three options it writes into scratch", %{
    task: task,
    run: run
  } do
    design_dir = Path.join(task.scratch_path, "design")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "exactly three distinct design options"
      assert prompt =~ "cat > #{design_dir}/manifest.json <<'MANIFEST'"
      assert prompt =~ "--window-size=1920,1080 --screenshot=#{design_dir}/<key>.png file://#{design_dir}/<key>.html"
      assert prompt =~ "Rail records the pick in #{design_dir}/picked"
      assert prompt =~ ~s(<ticket title="Invoice filters">\nFilter invoices by vendor.\n</ticket>)

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_design_run(run)
    assert File.dir?(design_dir)
  end
end
