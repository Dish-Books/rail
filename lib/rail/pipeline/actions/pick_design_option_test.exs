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

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :design)

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

    manifest =
      ~s({"options": [{"key": "cards", "title": "Cards"}, {"key": "table", "title": "Table"}, {"key": "timeline", "title": "Timeline"}]})

    File.write!(Path.join(design_dir, "manifest.json"), manifest)

    for key <- ["cards", "table", "timeline"] do
      File.write!(Path.join(design_dir, "#{key}.html"), "<h1>#{key}</h1>")
      File.write!(Path.join(design_dir, "#{key}.png"), "png")
    end

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_pick_design",
        started_at: DateTime.utc_now()
      })

    %{task: task, role: role, run: run, design_dir: design_dir, manifest: manifest}
  end

  test "records the pick and tells the designer to refine only it", %{task: task, run: run, design_dir: dir} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{}} = Pipeline.pick_design_option(system_scope(), run, "table")

    assert File.read!(Path.join(dir, "picked")) == "table"
    assert Enum.sort(File.ls!(dir)) == ["manifest.json", "picked", "table.html", "table.png"]
    assert %{picked: "table", options: [%{key: "table", title: "Table"}]} = Pipeline.read_design(task)
    assert [first | _rest] = Enum.map(Pipeline.list_run_events(run), & &1.line)
    assert first =~ "[human] I picked Table (table)."

    said = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)
    assert said =~ "save it again with save_design_option every time it changes"
    refute said =~ "keep it that way"
  end

  test "the picked option keeps everything the designer wrote about it", %{run: run, design_dir: dir} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    table = %{
      "key" => "table",
      "title" => "Table",
      "summary" => "Dense rows.",
      "good_at" => ["Many per screen"],
      "costs" => ["Hard to scan"],
      "assumptions" => "Fifty per page."
    }

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(%{"options" => ["not an option", %{"key" => "cards", "title" => "Cards"}, table]})
    )

    assert {:ok, %Run{}} = Pipeline.pick_design_option(system_scope(), run, "table")

    assert %{"options" => [^table]} = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  end

  test "an option that never had its screenshot taken is removed all the same", %{run: run, design_dir: dir} do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    File.rm!(Path.join(dir, "timeline.png"))

    assert {:ok, %Run{}} = Pipeline.pick_design_option(system_scope(), run, "table")

    assert Enum.sort(File.ls!(dir)) == ["manifest.json", "picked", "table.html", "table.png"]
  end

  test "a design that already has a pick is not picked again", %{run: run, design_dir: dir, manifest: manifest} do
    File.write!(Path.join(dir, "picked"), "cards")

    assert {:error, :already_picked} = Pipeline.pick_design_option(system_scope(), run, "table")

    assert Enum.sort(File.ls!(dir)) ==
             [
               "cards.html",
               "cards.png",
               "manifest.json",
               "picked",
               "table.html",
               "table.png",
               "timeline.html",
               "timeline.png"
             ]

    assert File.read!(Path.join(dir, "manifest.json")) == manifest
  end

  test "only an option the designer wrote can be picked", %{run: run, design_dir: dir, manifest: manifest} do
    assert {:error, :option_not_found} = Pipeline.pick_design_option(system_scope(), run, "grid")
    refute File.exists?(Path.join(dir, "picked"))

    assert Enum.sort(File.ls!(dir)) ==
             ["cards.html", "cards.png", "manifest.json", "table.html", "table.png", "timeline.html", "timeline.png"]

    assert File.read!(Path.join(dir, "manifest.json")) == manifest
  end

  test "nothing is picked before the designer writes its options", %{run: run, design_dir: dir} do
    File.rm!(Path.join(dir, "manifest.json"))

    assert {:error, :design_not_found} = Pipeline.pick_design_option(system_scope(), run, "cards")
  end

  test "nothing is picked while the designer is still working", %{run: run, design_dir: dir, manifest: manifest} do
    {:ok, working} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.pick_design_option(system_scope(), working, "cards")

    assert Enum.sort(File.ls!(dir)) ==
             ["cards.html", "cards.png", "manifest.json", "table.html", "table.png", "timeline.html", "timeline.png"]

    assert File.read!(Path.join(dir, "manifest.json")) == manifest
  end

  test "a task past design has nothing left to pick", %{task: task, run: run, design_dir: dir, manifest: manifest} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :architect})

    assert {:error, {:invalid_stage, :architect}} = Pipeline.pick_design_option(system_scope(), run, "cards")

    assert Enum.sort(File.ls!(dir)) ==
             ["cards.html", "cards.png", "manifest.json", "table.html", "table.png", "timeline.html", "timeline.png"]

    assert File.read!(Path.join(dir, "manifest.json")) == manifest
  end

  test "a pick the designer cannot hear about is not recorded", %{
    task: task,
    role: role,
    design_dir: dir,
    manifest: manifest
  } do
    {:ok, silent} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, :chat_unavailable} = Pipeline.pick_design_option(system_scope(), silent, "cards")
    refute File.exists?(Path.join(dir, "picked"))

    assert Enum.sort(File.ls!(dir)) ==
             ["cards.html", "cards.png", "manifest.json", "table.html", "table.png", "timeline.html", "timeline.png"]

    assert File.read!(Path.join(dir, "manifest.json")) == manifest
  end
end
