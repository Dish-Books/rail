defmodule Rail.Artifacts.Actions.MaterializeTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
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
          default_branch: "main",
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
  end
end
