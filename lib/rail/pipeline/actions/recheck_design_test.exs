defmodule Rail.Pipeline.Actions.RecheckDesignTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Recheck Design Workspace",
        external_id: "lin_ws_recheck_design",
        token: "lin_api_token_recheck_design",
        webhook_secret: "whsec_recheck_design"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Recheck Design Project 13701",
        github_repo: "org/recheck-design-13701",
        github_installation_id: 13_701,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_recheck_design_13701",
        linear_team_key: "P13701",
        default_branch: "main",
        clone_path: "/tmp/repos/recheck-design-13701",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
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

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_recheck_design_1",
      "identifier" => "RCD-1",
      "title" => "Recheck Design Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Recheck Design Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "lands a design the gate turned down once the canvas is published", %{task: task, roles: roles} do
    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Recheck Design Workspace 13704",
        external_id: "lin_ws_recheck_design_13704",
        token: "lin_api_token_recheck_design_13704",
        webhook_secret: "whsec_recheck_design_13704"
      })

    {:ok, designer_role} =
      Roles.update_role(system_scope(), roles[:design], %{
        name: "Designer"
      })

    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/design/valid-canvas",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          },
          %{
            "key" => "dir-2",
            "title" => "Bold Dark",
            "notes" => "Dark mode with high contrast neon highlights",
            "stillPath" => "dir-2.png"
          }
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :design,
        error: "Canvas URL could not be opened or returned 404/410",
        scratch_path: scratch_dir
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: designer_role.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    mock_design_uploads(2)

    assert {:ok, %Task{id: task_id, stage: :design, error: nil}} =
             Pipeline.recheck_design(task, url_probe: fn _uri -> true end)

    assert is_nil(Repo.get!(Task, task_id).error)
    assert %Run{stage_outcome: :done, error: nil} = Repo.reload!(run)

    design = Repo.one(from d in Design, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1)
    assert design.canvas_url == "https://claude.ai/design/valid-canvas"

    events = Repo.all(from e in RunEvent, where: e.run_id == ^run.id, order_by: [asc: e.seq])
    assert Enum.any?(events, fn e -> e.line =~ "[rail] Design re-checked: manifest v1 accepted." end)
  end

  test "reads the same manifest twice without turning it down", %{task: task, roles: roles} do
    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Recheck Design Workspace 13705",
        external_id: "lin_ws_recheck_design_13705",
        token: "lin_api_token_recheck_design_13705",
        webhook_secret: "whsec_recheck_design_13705"
      })

    {:ok, _designer_role} =
      Roles.update_role(system_scope(), roles[:design], %{
        name: "Designer"
      })

    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/design/canvas-same",
        "version" => 2,
        "pickedKey" => "dir-1",
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          },
          %{
            "key" => "dir-2",
            "title" => "Bold Dark",
            "notes" => "Dark mode with high contrast neon highlights",
            "stillPath" => "dir-2.png"
          }
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :design,
        error: "Initial gate failure",
        scratch_path: scratch_dir
      })

    mock_design_uploads(2)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, scratch_dir, url_probe: fn _url -> true end)

    mock_design_uploads(4)

    assert {:ok, %Task{error: nil}} =
             Pipeline.recheck_design(task, url_probe: fn _uri -> true end)

    assert {:ok, %Task{error: nil}} =
             Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
  end

  test "says why a design still does not hold up, and leaves the stage failed", %{task: task, roles: roles} do
    {:ok, designer_role} =
      Roles.update_role(system_scope(), roles[:design], %{
        name: "Designer"
      })

    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "invalid-not-https-url",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          },
          %{
            "key" => "dir-2",
            "title" => "Bold Dark",
            "notes" => "Dark mode with high contrast neon highlights",
            "stillPath" => "dir-2.png"
          }
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :design,
        error: "Initial failure",
        scratch_path: scratch_dir
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: designer_role.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, reason} = Pipeline.recheck_design(task)
    assert reason =~ "absolute https URL"

    assert Repo.get!(Task, task.id).error =~ "absolute https URL"
    assert %Run{stage_outcome: :in_progress, error: design_error} = Repo.reload!(run)
    assert design_error =~ "absolute https URL"

    events = Repo.all(from e in RunEvent, where: e.run_id == ^run.id, order_by: [asc: e.seq])

    assert Enum.any?(events, fn e ->
             e.line =~ "[rail] Design re-check turned it down:" and e.line =~ "absolute https URL"
           end)
  end

  test "returns error when designer is actively running", %{task: task, roles: roles} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :design})

    {:ok, _running} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:design].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, "The Designer is still running; wait for it to finish."} =
             Pipeline.recheck_design(task)
  end

  test "noops and returns ok when task stage is not design", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    assert {:ok, %Task{stage: :engineer}} = Pipeline.recheck_design(task)
  end

  test "fails when manifest is missing pickedKey after a pick", %{task: task, roles: roles} do
    {:ok, _design_run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:design].id,
        conversation_id: "sess_design",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/canvas/pick-check",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          },
          %{
            "key" => "dir-2",
            "title" => "Bold Dark",
            "notes" => "Dark mode with high contrast neon highlights",
            "stillPath" => "dir-2.png"
          }
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :design,
        scratch_path: scratch_dir
      })

    mock_design_uploads(2)

    {:ok, design} =
      Artifacts.capture_design(system_scope(), task, scratch_dir, url_probe: fn _url -> true end)

    # The human picks dir-1, so the manifest must keep that choice.
    {:ok, _picked} = design |> Design.changeset(%{picked_key: "dir-1"}) |> Repo.update()

    {:ok, task} =
      Pipeline.update_task(task, %{stage: :design})

    mock_design_uploads(2)

    assert {:error, reason} = Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
    assert reason =~ "Design manifest is missing pickedKey (expected \"dir-1\")."
  end

  test "fails when manifest pickedKey does not match chosen direction", %{task: task, roles: roles} do
    {:ok, _design_run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:design].id,
        conversation_id: "sess_design",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/canvas/pick-check",
        "version" => 1,
        "pickedKey" => "dir-1",
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          },
          %{
            "key" => "dir-2",
            "title" => "Bold Dark",
            "notes" => "Dark mode with high contrast neon highlights",
            "stillPath" => "dir-2.png"
          }
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :design,
        scratch_path: scratch_dir
      })

    mock_design_uploads(2)

    {:ok, design} =
      Artifacts.capture_design(system_scope(), task, scratch_dir, url_probe: fn _url -> true end)

    # The human picks dir-1, then the agent rewrites the manifest with a different pick.
    {:ok, _picked} = design |> Design.changeset(%{picked_key: "dir-1"}) |> Repo.update()

    {:ok, task} =
      Pipeline.update_task(task, %{stage: :design})

    manifest_path = Path.join(design_dir, "manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    File.write!(manifest_path, Jason.encode!(%{manifest | "pickedKey" => "dir-2"}))

    mock_design_uploads(2)

    assert {:error, reason} = Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
    assert reason =~ "does not match chosen direction (dir-1)"
  end

  test "fails when manifest does not contain chosen direction", %{task: task} do
    directions = [
      %{
        "key" => "dir-other",
        "title" => "Other",
        "notes" => "Other notes",
        "stillPath" => "dir-1.png"
      }
    ]

    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/canvas/pick-check",
        "version" => 1,
        "pickedKey" => "dir-1",
        "directions" => directions
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :design,
        scratch_path: scratch_dir
      })

    mock_design_uploads(2)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, scratch_dir, url_probe: fn _url -> true end)

    mock_design_uploads(2)

    assert {:error, reason} = Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
    assert reason =~ "Manifest missing picked direction: dir-1"
  end

  test "computes design_manifest_stamp and handles missing files" do
    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/design/canvas-1",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          },
          %{
            "key" => "dir-2",
            "title" => "Bold Dark",
            "notes" => "Dark mode with high contrast neon highlights",
            "stillPath" => "dir-2.png"
          }
        ]
      })
    )

    stamp = Pipeline.design_manifest_stamp(scratch_dir)
    assert stamp =~ ~r/^\d+:\d+$/

    assert is_nil(Pipeline.design_manifest_stamp("/tmp/nonexistent_design_dir_#{System.unique_integer([:positive])}"))
    assert is_nil(Pipeline.design_manifest_stamp(nil))
  end

  test "computes design_manifest_stamp from the task's scratch directory", %{task: task} do
    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
    File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

    File.write!(
      Path.join(design_dir, "manifest.json"),
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/design/canvas-1",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          },
          %{
            "key" => "dir-2",
            "title" => "Bold Dark",
            "notes" => "Dark mode with high contrast neon highlights",
            "stillPath" => "dir-2.png"
          }
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{
        scratch_path: scratch_dir
      })

    assert Pipeline.design_manifest_stamp(task) =~ ~r/^\d+:\d+$/
    assert Pipeline.design_manifest_stamp(scratch_dir) =~ ~r/^\d+:\d+$/

    # A manifest sitting at the scratch root rather than under design/ is not one.
    root_dir = create_temp_git_repo()
    File.write!(Path.join(root_dir, "manifest.json"), "{}")
    assert is_nil(Pipeline.design_manifest_stamp(root_dir))
  end

  test "reads the manifest from the task's scratch directory and nowhere else", %{task: task} do
    {:ok, _workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Recheck Design Workspace 13706",
        external_id: "lin_ws_recheck_design_13706",
        token: "lin_api_token_recheck_design_13706",
        webhook_secret: "whsec_recheck_design_13706"
      })

    scratch_dir = Path.join("/tmp", "rail_design_scratch_#{System.unique_integer([:positive])}")
    design_dir = Path.join(scratch_dir, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")

    manifest =
      Jason.encode!(%{
        "canvasUrl" => "https://claude.ai/design/canvas-1",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{
            "key" => "dir-1",
            "title" => "Minimal Light",
            "notes" => "Clean aesthetic with spacious white layout",
            "stillPath" => "dir-1.png"
          }
        ]
      })

    File.write!(Path.join(design_dir, "manifest.json"), manifest)

    {:ok, scratch_task} =
      Pipeline.update_task(task, %{
        stage: :design,
        scratch_path: scratch_dir,
        worktree_path: "/tmp/rail-removed-worktree"
      })

    mock_design_uploads(1)

    assert {:ok, %Task{}} =
             Pipeline.recheck_design(scratch_task, url_probe: fn _uri -> true end)

    # A manifest written into the worktree instead is a design Rail never saw.
    {:ok, elsewhere_task} =
      Pipeline.update_task(scratch_task, %{
        scratch_path: Path.join("/tmp", "rail_design_empty_#{System.unique_integer([:positive])}")
      })

    assert {:error, err} = Pipeline.recheck_design(elsewhere_task, url_probe: fn _uri -> true end)
    assert err =~ "No design manifest found"
  end
end
