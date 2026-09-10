defmodule Rail.Artifacts.Actions.MaterializeTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias Rail.Domain.Embeds.DesignDirection
  alias Rail.Domain.Embeds.QaArtifact
  alias Rail.Domain.Embeds.QaRow
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  @tmp_base "tmp/test_materialize"

  setup do
    dest_dir = Path.join(@tmp_base, "dest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest_dir)

    {:ok, ws} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Materialize Workspace 12402",
        external_id: "lin_ws_materialize_12402",
        token: "lin_api_token_materialize_12402",
        webhook_secret: "whsec_materialize_12402"
      })

    on_exit(fn -> File.rm_rf(dest_dir) end)
    {:ok, dest_dir: dest_dir, ws: ws}
  end

  describe "materialize/4" do
    test "rejects unauthorized scope", %{dest_dir: dest_dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.materialize(scope, "tsk_1", dest_dir)
    end

    test "materializes %Design{} downloading stills and writing manifest", %{dest_dir: dest_dir} do
      scope = Scope.for_system()

      design = %Design{
        version: 1,
        canvas_url: "https://canvas.example.com/1",
        picked_key: "dir_1",
        directions: [
          %DesignDirection{
            key: "dir_1",
            title: "Direction 1",
            notes: "Notes 1",
            still_url: "https://uploads.linear.app/asset/still_1.png"
          }
        ]
      }

      Req.Test.expect(Rail.Linear, fn conn ->
        assert conn.request_path == "/asset/still_1.png"
        Plug.Conn.send_resp(conn, 200, "DOWNLOADED_STILL_BINARY")
      end)

      assert {:ok, design_dir} = Artifacts.materialize(scope, design, dest_dir)
      assert File.exists?(Path.join(design_dir, "manifest.json"))
      assert File.exists?(Path.join(design_dir, "still_dir_1.png"))
      assert File.read!(Path.join(design_dir, "still_dir_1.png")) == "DOWNLOADED_STILL_BINARY"

      manifest = Jason.decode!(File.read!(Path.join(design_dir, "manifest.json")))
      assert manifest["canvasUrl"] == "https://canvas.example.com/1"
      assert [%{"key" => "dir_1"}] = manifest["directions"]
    end

    test "materializes %Demo{} downloading frames and writing manifest", %{dest_dir: dest_dir} do
      scope = Scope.for_system()

      demo = %Demo{
        version: 1,
        outcome: "recorded",
        note: nil,
        segments: [
          %DemoSegment{
            criterion_index: 1,
            criterion: "Passes check",
            outcome: :recorded,
            frames: [
              %DemoFrame{
                url: "https://uploads.linear.app/asset/frame_1.png",
                hold_ms: 1000,
                caption: "Screen 1"
              }
            ]
          }
        ]
      }

      Req.Test.expect(Rail.Linear, fn conn ->
        assert conn.request_path == "/asset/frame_1.png"
        Plug.Conn.send_resp(conn, 200, "DOWNLOADED_FRAME_BINARY")
      end)

      assert {:ok, demo_dir} = Artifacts.materialize(scope, demo, dest_dir)
      assert File.exists?(Path.join(demo_dir, "manifest.json"))
      assert File.exists?(Path.join(demo_dir, "ac1_0.png"))
      assert File.read!(Path.join(demo_dir, "ac1_0.png")) == "DOWNLOADED_FRAME_BINARY"

      manifest = Jason.decode!(File.read!(Path.join(demo_dir, "manifest.json")))
      assert manifest["outcome"] == "recorded"
      assert [%{"criterionIndex" => 1, "frames" => [%{"path" => "ac1_0.png"}]}] = manifest["segments"]
    end

    test "materializes %QaReport{} writing text and image artifacts", %{dest_dir: dest_dir} do
      scope = Scope.user_scope()

      report = %QaReport{
        commit: "c1234",
        session: %{"port" => 4000},
        rows: [
          %QaRow{
            id: "c1",
            check: "Log check",
            result: :pass,
            severity: :blocker,
            artifacts: [
              %QaArtifact{name: "log.txt", kind: :text, text: "ALL CHECKS PASSED"},
              %QaArtifact{name: "evidence.png", kind: :image, url: "https://uploads.linear.app/asset/qa_ev.png"}
            ]
          }
        ]
      }

      Req.Test.expect(Rail.Linear, fn conn ->
        assert conn.request_path == "/asset/qa_ev.png"
        Plug.Conn.send_resp(conn, 200, "QA_IMAGE_BINARY")
      end)

      assert {:ok, qa_dir} = Artifacts.materialize(scope, report, dest_dir)
      assert File.exists?(Path.join(qa_dir, "manifest.json"))
      assert File.read!(Path.join(qa_dir, "log.txt")) == "ALL CHECKS PASSED"
      assert File.read!(Path.join(qa_dir, "evidence.png")) == "QA_IMAGE_BINARY"

      manifest = Jason.decode!(File.read!(Path.join(qa_dir, "manifest.json")))
      assert manifest["commit"] == "c1234"
      assert [%{"id" => "c1", "artifacts" => [_art1, _art2]}] = manifest["rows"]
    end

    test "materializes %QaReport{} with only text artifacts when no Linear workspace exists", %{dest_dir: dest_dir} do
      scope = Scope.for_system()
      Repo.delete_all(LinearWorkspace)

      report = %QaReport{
        commit: "text_only_commit",
        session: %{"port" => 4000},
        rows: [
          %QaRow{
            id: "c_txt",
            check: "Console check",
            result: :pass,
            severity: :minor,
            artifacts: [
              %QaArtifact{name: "console.log", kind: :text, text: "NO ERRORS"}
            ]
          }
        ]
      }

      assert {:ok, qa_dir} = Artifacts.materialize(scope, report, dest_dir)
      assert File.exists?(Path.join(qa_dir, "manifest.json"))
      assert File.read!(Path.join(qa_dir, "console.log")) == "NO ERRORS"

      manifest = Jason.decode!(File.read!(Path.join(qa_dir, "manifest.json")))
      assert manifest["commit"] == "text_only_commit"
    end

    test "materializes QA report by %Task{} resolving project workspace token automatically", %{
      dest_dir: dest_dir,
      ws: ws
    } do
      scope = Scope.for_system()

      {:ok, project} =
        Projects.create_project(system_scope(), %{
          name: "Materialize Project 12403",
          github_repo: "org/materialize-12403",
          github_installation_id: 12_403,
          linear_team_id: "team_materialize_12403",
          linear_team_key: "P12403",
          clone_path: "/tmp/repos/materialize-12403",
          linear_state_ids: %{
            "triage" => "st_triage",
            "backlog" => "st_backlog",
            "in_progress" => "st_in_progress",
            "done" => "st_done",
            "canceled" => "st_canceled"
          },
          linear_workspace_id: ws.id
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_materialize_12404",
        "identifier" => "TSK-12404",
        "title" => "Task 12404"
      })

      {:ok, issue_12404} = Issues.capture_issue(system_scope(), project, "Task 12404")

      LinearMock.mock_update_issue_success(%{"id" => "lin_task_materialize_12404"})

      {:ok, task} = Pipeline.bring_local(system_scope(), issue_12404)

      {:ok, _qa} =
        %QaReport{}
        |> QaReport.changeset(%{
          task_id: task.id,
          commit: "task_commit",
          session: %{},
          rows: [
            %{
              id: "t1",
              check: "Task test",
              result: :pass,
              severity: :blocker,
              artifacts: [
                %{name: "img.png", kind: :image, url: "https://uploads.linear.app/asset/task_img.png"}
              ]
            }
          ]
        })
        |> Repo.insert()

      Req.Test.expect(Rail.Linear, fn conn ->
        assert conn.request_path == "/asset/task_img.png"
        Plug.Conn.send_resp(conn, 200, "TASK_IMAGE_DATA")
      end)

      assert {:ok, qa_dir} = Artifacts.materialize(scope, task, dest_dir, kind: :qa)
      assert File.exists?(Path.join(qa_dir, "img.png"))
      assert File.read!(Path.join(qa_dir, "img.png")) == "TASK_IMAGE_DATA"

      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 200, "TASK_IMAGE_DATA_2")
      end)

      assert {:ok, _qa_dir2} = Artifacts.materialize(scope, task.id, dest_dir, kind: :qa)
    end

    test "materializes by task_id for all kinds", %{dest_dir: dest_dir} do
      scope = Scope.for_system()

      {:ok, _design} =
        %Design{}
        |> Design.changeset(%{
          task_id: "tsk_mat_all",
          canvas_url: "https://canvas.example.com",
          directions: []
        })
        |> Repo.insert()

      {:ok, _demo} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_mat_all",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "declined",
          note: "No UI"
        })
        |> Repo.insert()

      {:ok, _qa} =
        %QaReport{}
        |> QaReport.changeset(%{
          task_id: "tsk_mat_all",
          session: %{},
          rows: []
        })
        |> Repo.insert()

      assert {:ok, results} = Artifacts.materialize(scope, "tsk_mat_all", dest_dir, kind: :all)
      assert byte_size(results[:design]) > 0
      assert byte_size(results[:demo]) > 0
      assert byte_size(results[:qa]) > 0

      # Individual kind lookups
      assert {:ok, _dsg_dir} = Artifacts.materialize(scope, "tsk_mat_all", dest_dir, kind: :design)
      assert {:ok, _dmo_dir} = Artifacts.materialize(scope, "tsk_mat_all", dest_dir, kind: :demo)
      assert {:ok, _qa_dir} = Artifacts.materialize(scope, "tsk_mat_all", dest_dir, kind: :qa)

      # Missing artifact errors
      assert {:error, :design_not_found} = Artifacts.materialize(scope, "tsk_none", dest_dir, kind: :design)
      assert {:error, :demo_not_found} = Artifacts.materialize(scope, "tsk_none", dest_dir, kind: :demo)
      assert {:error, :qa_report_not_found} = Artifacts.materialize(scope, "tsk_none", dest_dir, kind: :qa)

      # Target as struct and atom
      assert {:ok, _demo_path} = Artifacts.materialize(scope, %{id: "tsk_mat_all"}, dest_dir, kind: :demo)
      assert {:ok, _demo_path2} = Artifacts.materialize(scope, :tsk_mat_all, dest_dir, kind: :demo)

      # materialize_all when no artifacts exist
      assert {:ok, %{}} = Artifacts.materialize(scope, "tsk_empty_all", dest_dir, kind: :all)
    end

    test "handles dest directories already ending in kind suffix", %{dest_dir: dest_dir, ws: ws} do
      scope = Scope.for_system()

      design = %Design{
        version: 1,
        canvas_url: "https://canvas.example.com",
        directions: [
          %DesignDirection{
            key: "d_sub",
            title: "T",
            notes: "N",
            still_url: nil
          }
        ]
      }

      dest_design = Path.join(dest_dir, "design")
      File.mkdir_p!(dest_design)
      assert {:ok, ^dest_design} = Artifacts.materialize(scope, design, dest_design, token: "custom_tok")

      demo = %Demo{
        version: 1,
        outcome: "recorded",
        segments: [
          %DemoSegment{
            criterion_index: 1,
            criterion: "C",
            outcome: :recorded,
            frames: [
              %DemoFrame{
                url: "",
                hold_ms: 1000
              }
            ]
          }
        ]
      }

      dest_demo = Path.join(dest_dir, "demo")
      File.mkdir_p!(dest_demo)
      assert {:ok, ^dest_demo} = Artifacts.materialize(scope, demo, dest_demo, workspace: ws)

      report = %QaReport{
        commit: "c1",
        session: %{},
        rows: [
          %QaRow{
            id: "q1",
            check: "C",
            result: :pass,
            severity: :cosmetic,
            artifacts: [
              %QaArtifact{name: "no_url.png", kind: :image, url: nil}
            ]
          }
        ]
      }

      dest_qa = Path.join(dest_dir, "qa")
      File.mkdir_p!(dest_qa)
      assert {:ok, ^dest_qa} = Artifacts.materialize(scope, report, dest_qa)
    end

    test "handles project token resolution variants and missing workspace", %{dest_dir: dest_dir, ws: ws} do
      scope = Scope.for_system()

      project_loaded = %Project{linear_workspace: ws}

      {:ok, project_with_id} =
        Projects.create_project(system_scope(), %{
          name: "Materialize Project 12405",
          github_repo: "org/materialize-12405",
          github_installation_id: 12_405,
          linear_team_id: "team_materialize_12405",
          linear_team_key: "P12405",
          clone_path: "/tmp/repos/materialize-12405",
          linear_state_ids: %{
            "triage" => "st_triage",
            "backlog" => "st_backlog",
            "in_progress" => "st_in_progress",
            "done" => "st_done",
            "canceled" => "st_canceled"
          },
          linear_workspace_id: ws.id
        })

      demo = %Demo{
        version: 1,
        outcome: "declined",
        note: "none",
        segments: []
      }

      assert {:ok, _res1} = Artifacts.materialize(scope, demo, dest_dir, project: project_loaded)
      assert {:ok, _res2} = Artifacts.materialize(scope, demo, dest_dir, project: project_with_id)

      # When no workspace exists at all
      Repo.delete_all(LinearWorkspace)
      assert {:error, :no_workspace_token} = Artifacts.materialize(scope, demo, dest_dir)

      # Project referencing non-existent workspace
      assert {:error, :no_workspace_token} = Artifacts.materialize(scope, demo, dest_dir, project: project_with_id)
    end

    test "handles download failures across design, demo, and QA", %{dest_dir: dest_dir} do
      scope = Scope.for_system()

      {:ok, _ws} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Materialize Workspace 12406",
          external_id: "lin_ws_materialize_12406",
          token: "lin_api_token_materialize_12406",
          webhook_secret: "whsec_materialize_12406"
        })

      design = %Design{
        version: 1,
        canvas_url: "https://canvas.example.com",
        directions: [
          %DesignDirection{
            key: "fail_dir",
            title: "F",
            notes: "N",
            still_url: "https://uploads.linear.app/asset/fail_still.png"
          }
        ]
      }

      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Server Error")
      end)

      assert {:error, {:download_failed, 500, _url}} = Artifacts.materialize(scope, design, dest_dir)

      demo = %Demo{
        version: 1,
        outcome: "recorded",
        segments: [
          %DemoSegment{
            criterion_index: 1,
            criterion: "C",
            outcome: :recorded,
            frames: [
              %DemoFrame{
                url: "https://uploads.linear.app/asset/fail_frame.png",
                hold_ms: 1000
              }
            ]
          }
        ]
      }

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Artifacts.materialize(scope, demo, dest_dir)

      report = %QaReport{
        commit: "c1",
        session: %{},
        rows: [
          %QaRow{
            id: "q_fail",
            check: "C",
            result: :pass,
            severity: :cosmetic,
            artifacts: [
              %QaArtifact{name: "fail_qa.png", kind: :image, url: "https://uploads.linear.app/asset/fail_qa.png"}
            ]
          }
        ]
      }

      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      assert {:error, {:download_failed, 404, _url}} = Artifacts.materialize(scope, report, dest_dir)
    end
  end
end
