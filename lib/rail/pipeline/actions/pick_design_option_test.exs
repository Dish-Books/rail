defmodule Rail.Pipeline.Actions.PickDesignOptionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :design,
        name: "design role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the design agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_pick_design_1", "identifier" => "PKD-1", "title" => "Pick Design"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Pick Design"})
    {:ok, task} = Pipeline.create_task(issue, :design)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "cards", "title": "Cards"}, {"key": "table", "title": "Table"}]})
    )

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_pick_design",
        started_at: DateTime.utc_now()
      })

    %{task: task, role: role, run: run, design_dir: design_dir}
  end

  test "records the pick and tells the designer to refine only it", %{run: run, design_dir: dir} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{}} = Pipeline.pick_design_option(run, "table")

    assert File.read!(Path.join(dir, "picked")) == "table"
    assert [first | _rest] = Enum.map(Pipeline.list_run_events(run), & &1.line)
    assert first =~ "[human] I picked Table (table)."
  end

  test "a design that already has a pick is not picked again", %{run: run, design_dir: dir} do
    File.write!(Path.join(dir, "picked"), "cards")

    assert {:error, :already_picked} = Pipeline.pick_design_option(run, "table")
  end

  test "only an option the designer wrote can be picked", %{run: run, design_dir: dir} do
    assert {:error, :option_not_found} = Pipeline.pick_design_option(run, "timeline")
    refute File.exists?(Path.join(dir, "picked"))
  end

  test "nothing is picked before the designer writes its options", %{run: run, design_dir: dir} do
    File.rm!(Path.join(dir, "manifest.json"))

    assert {:error, :design_not_found} = Pipeline.pick_design_option(run, "cards")
  end

  test "nothing is picked while the designer is still working", %{run: run} do
    {:ok, working} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.pick_design_option(working, "cards")
  end

  test "a task past design has nothing left to pick", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :architect})

    assert {:error, {:invalid_stage, :architect}} = Pipeline.pick_design_option(run, "cards")
  end

  test "a pick the designer cannot hear about is not recorded", %{task: task, role: role, design_dir: dir} do
    {:ok, silent} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, :chat_unavailable} = Pipeline.pick_design_option(silent, "cards")
    refute File.exists?(Path.join(dir, "picked"))
  end
end
