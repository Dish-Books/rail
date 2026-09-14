defmodule Rail.ArtifactsTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Projects
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_artifacts_facade"

  setup do
    dir = Path.join(@tmp_base, "facade_#{System.unique_integer([:positive])}")
    Enum.each(["demo", "qa"], &File.mkdir_p!(Path.join(dir, &1)))

    {:ok, ws} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Artifacts Facade Workspace",
        external_id: "lin_ws_artifacts_facade",
        token: "lin_api_token_artifacts_facade",
        webhook_secret: "whsec_artifacts_facade"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Artifacts Facade Project",
        github_repo: "org/artifacts-facade",
        github_installation_id: 12_001,
        linear_workspace_id: ws.id,
        linear_team_id: "team_artifacts_facade",
        linear_team_key: "AFC",
        default_branch: "main",
        clone_path: "/tmp/repos/artifacts-facade"
      })

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, project: project, ws: ws}
  end

  describe "Rail.Artifacts facade" do
    test "delegates demo actions including mark_demo_stale", %{dir: dir, project: project} do
      scope = Scope.for_system()
      ArtifactHelpers.write_demo_manifest(Path.join(dir, "demo"))

      assert {:ok, %{}} = Artifacts.read_demo(scope, dir)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/facade_dmo",
        asset_url: "https://uploads.linear.app/facade_dmo/ac1-0.png",
        asset_id: "ast_facade_dmo"
      )

      assert {:ok, %Demo{stale: false}} =
               Artifacts.capture_demo(scope, "tsk_facade_dmo", dir, project: project)

      assert {:ok, %Demo{stale: true}} = Artifacts.mark_demo_stale(scope, "tsk_facade_dmo")
    end

    test "delegates qa actions and asset helper", %{dir: dir, project: project} do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(Path.join(dir, "qa"))

      assert {:ok, %{}} = Artifacts.read_qa_report(scope, dir)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/facade_qar",
        asset_url: "https://uploads.linear.app/facade_qar/shot.png",
        asset_id: "ast_facade_qar"
      )

      assert {:ok, %QaReport{task_id: "tsk_facade_qar"}} =
               Artifacts.capture_qa_report(scope, "tsk_facade_qar", dir, project: project)

      assert Artifacts.asset_url(:demo, "ast_123") == "/assets/demo/ast_123"

      assert {:ok, %{url: "https://uploads.linear.app/facade_qar/shot.png"}} =
               Artifacts.get_asset(scope, :qa, "shot.png")

      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 200, "SHOT_BYTES")
      end)

      dest_dir = Path.join(dir, "mat_out")
      qa_mat_dir = Path.join(dest_dir, "qa")
      assert {:ok, ^qa_mat_dir} = Artifacts.materialize(scope, "tsk_facade_qar", dest_dir, kind: :qa)
    end
  end
end
