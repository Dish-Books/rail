defmodule Rail.ArtifactsTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_artifacts_facade"

  setup do
    dir = Path.join(@tmp_base, "facade_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ws = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws.id})

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, project: project, ws: ws}
  end

  describe "Rail.Artifacts facade" do
    test "delegates read and capture actions for design", %{dir: dir, project: project} do
      scope = Scope.for_system()
      ArtifactHelpers.write_design_manifest(dir)

      assert {:ok, %{}} = Artifacts.read_design(scope, dir, url_probe: fn _url -> true end)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/facade_dsg",
        asset_url: "https://uploads.linear.app/facade_dsg/still_a.png",
        asset_id: "ast_facade_dsg"
      )

      assert {:ok, %Design{version: 1}} =
               Artifacts.capture_design(scope, "tsk_facade_1", dir,
                 project: project,
                 url_probe: fn _url -> true end
               )
    end

    test "delegates demo actions including mark_demo_stale", %{dir: dir, project: project} do
      scope = Scope.for_system()
      ArtifactHelpers.write_demo_manifest(dir)

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
      ArtifactHelpers.write_qa_manifest(dir)

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
