defmodule Rail.Pipeline.Utils.DesignRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DesignRunFinished
  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Design Workspace",
        external_id: "lin_ws_settle_design",
        token: "lin_api_token_settle_design",
        webhook_secret: "whsec_settle_design"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Design Project 14602",
        github_repo: "org/settle-design-14602",
        github_installation_id: 14_602,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_design_14602",
        linear_team_key: "P14602",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-design-14602",
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
      "id" => "lin_settle_design_1",
      "identifier" => "S14602-1",
      "title" => "Settle Design Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Design Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  test "a designer that left no manifest records that on its run", %{task: task, roles: roles} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :design})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:design].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert %Run{error: error} = design_run_finished(Repo.preload(run, [:task, :role], force: true), [])
    assert error =~ "manifest"
    assert %Task{stage: :design} = Repo.get!(Task, task.id)
  end

  describe "capturing the design" do
    test "designer run settlement fails when manifest is missing", %{task: task, roles: roles} do
      {:ok, task} =
        Pipeline.update_task(task, %{
          stage: :design
        })

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert %Run{error: err} = design_run_finished(Repo.preload(run, [:task, :role], force: true), [])

      assert %Task{stage: :design} = Repo.get!(Task, task.id)

      assert err =~ "No design manifest found at"
    end

    test "designer run settlement populates task.design when manifest is valid", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14602",
          external_id: "lin_ws_settle_run_14602",
          token: "lin_api_token_settle_run_14602",
          webhook_secret: "whsec_settle_run_14602"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join(worktree_dir, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/canvas/v1",
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
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      assert %Run{error: nil} =
               design_run_finished(Repo.preload(run, [:task, :role], force: true), url_probe: fn _uri -> true end)

      assert %Task{stage: :design} = Repo.get!(Task, task.id)

      designs = Repo.all(from d in Rail.Artifacts.Schemas.Design, where: d.task_id == ^task.id)
      assert length(designs) == 1
      assert hd(designs).canvas_url == "https://claude.ai/canvas/v1"
    end

    test "fails when manifest no longer contains outstanding pickedKey", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14603",
          external_id: "lin_ws_settle_run_14603",
          token: "lin_api_token_settle_run_14603",
          webhook_secret: "whsec_settle_run_14603"
        })

      directions = [
        %{
          "key" => "dir-other",
          "title" => "Other",
          "notes" => "Notes",
          "stillPath" => "dir-1.png"
        }
      ]

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join(worktree_dir, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
          "pickedKey" => "dir-1",
          "directions" => directions
        })
      )

      {:ok, task} =
        Pipeline.update_task(task, %{
          stage: :design,
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert %Run{error: err} =
               design_run_finished(Repo.preload(run, [:task, :role], force: true), url_probe: fn _uri -> true end)

      assert err =~ "Manifest missing picked direction: dir-1"
    end

    test "fails when manifest version is not incremented after a pick or revision", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14604",
          external_id: "lin_ws_settle_run_14604",
          token: "lin_api_token_settle_run_14604",
          webhook_secret: "whsec_settle_run_14604"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join(worktree_dir, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
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
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert %Run{error: err} =
               design_run_finished(Repo.preload(run, [:task, :role], force: true), url_probe: fn _uri -> true end)

      assert err =~ "Manifest version must be incremented after a pick or revision."
    end

    test "fails when manifest is missing pickedKey after a pick", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14605",
          external_id: "lin_ws_settle_run_14605",
          token: "lin_api_token_settle_run_14605",
          webhook_secret: "whsec_settle_run_14605"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join(worktree_dir, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
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
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert %Run{error: err} =
               design_run_finished(Repo.preload(run, [:task, :role], force: true), url_probe: fn _uri -> true end)

      assert err =~ "Design manifest is missing pickedKey (expected \"dir-1\")."
    end

    test "fails when manifest pickedKey does not match previously chosen direction", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14606",
          external_id: "lin_ws_settle_run_14606",
          token: "lin_api_token_settle_run_14606",
          webhook_secret: "whsec_settle_run_14606"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join(worktree_dir, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
          "pickedKey" => "dir-2",
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
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert %Run{error: err} =
               design_run_finished(Repo.preload(run, [:task, :role], force: true), url_probe: fn _uri -> true end)

      assert err =~ "Design manifest pickedKey (dir-2) does not match chosen direction (dir-1)."
    end

    test "supports settling with scratch_path and valid transition", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14607",
          external_id: "lin_ws_settle_run_14607",
          token: "lin_api_token_settle_run_14607",
          webhook_secret: "whsec_settle_run_14607"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join(worktree_dir, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
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
          worktree_path: "/tmp/rail-removed-worktree"
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: worktree_dir})

      assert %Run{error: nil} =
               design_run_finished(Repo.preload(run, [:task, :role], force: true), url_probe: fn _uri -> true end)
    end

    test "supports settling with scratch_dir and valid transition", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14608",
          external_id: "lin_ws_settle_run_14608",
          token: "lin_api_token_settle_run_14608",
          webhook_secret: "whsec_settle_run_14608"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join(worktree_dir, "design")
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
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
          worktree_path: "/tmp/rail-removed-worktree"
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: worktree_dir})

      assert %Run{error: nil} =
               design_run_finished(Repo.preload(run, [:task, :role], force: true), url_probe: fn _uri -> true end)
    end
  end
end
