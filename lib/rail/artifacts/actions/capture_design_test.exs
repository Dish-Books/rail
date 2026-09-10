defmodule Rail.Artifacts.Actions.CaptureDesignTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Embeds.DesignDirection
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_capture_design"

  setup do
    dir = Path.join(@tmp_base, "design_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, ws} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Capture Design Workspace 12102",
        external_id: "lin_ws_capture_design_12102",
        token: "lin_api_token_capture_design_12102",
        webhook_secret: "whsec_capture_design_12102"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture Design Project 12103",
        github_repo: "org/capture-design-12103",
        github_installation_id: 12_103,
        linear_team_id: "team_capture_design_12103",
        linear_team_key: "P12103",
        clone_path: "/tmp/repos/capture-design-12103",
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
      "id" => "lin_dsg_iss",
      "identifier" => "ISS-12104",
      "title" => "Capture Design Issue 12104"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Capture Design Issue 12104")

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, project: project, issue: issue, ws: ws}
  end

  describe "capture_design/4" do
    test "rejects unauthorized scope", %{dir: dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.capture_design(scope, "tsk_1", dir)
    end

    test "captures valid design manifest with still uploads and comment creation", %{
      dir: dir,
      issue: issue,
      project: project
    } do
      scope = Scope.for_system()
      ArtifactHelpers.write_design_manifest(dir)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dsg_1",
        asset_url: "https://uploads.linear.app/dsg_1/still_a.png",
        asset_id: "ast_dsg_1"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "lin_cmt_dsg_1",
        "body" => "Design comment"
      })

      passing_probe = fn _url -> true end

      assert {:ok,
              %Design{
                version: 1,
                linear_comment_id: "lin_cmt_dsg_1",
                directions: [
                  %DesignDirection{
                    still_url: "https://uploads.linear.app/dsg_1/still_a.png",
                    linear_asset_id: "ast_dsg_1"
                  }
                ]
              }} =
               Artifacts.capture_design(scope, "tsk_design_cap_1", dir,
                 issue: issue,
                 project: project,
                 url_probe: passing_probe
               )

      # Next capture auto-increments version
      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dsg_2",
        asset_url: "https://uploads.linear.app/dsg_2/still_a.png",
        asset_id: "ast_dsg_2"
      )

      assert {:ok, %Design{version: 2}} =
               Artifacts.capture_design(scope, "tsk_design_cap_1", dir,
                 project: project,
                 url_probe: passing_probe
               )
    end

    test "propagates validator failure", %{dir: dir} do
      scope = Scope.for_system()
      File.write!(Path.join(dir, "manifest.json"), "{invalid")

      assert {:error, msg} = Artifacts.capture_design(scope, "tsk_err", dir)
      assert msg =~ "Failed to parse design manifest"
    end

    test "handles subfolder design, keyword list args, and user/atom target", %{
      dir: dir,
      project: project
    } do
      scope = Scope.user_scope()
      dsg_sub = Path.join(dir, "design")
      File.mkdir_p!(dsg_sub)
      ArtifactHelpers.write_design_manifest(dsg_sub)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dsg_sub",
        asset_url: "https://uploads.linear.app/dsg_sub/still_a.png",
        asset_id: "ast_dsg_sub"
      )

      # Target as struct, dir as parent with subfolder design, opts as 3rd arg
      assert {:ok, %Design{}} =
               Artifacts.capture_design(scope, %{id: "tsk_dsg_struct"},
                 scratch_dir: dir,
                 project: project,
                 url_probe: fn _url -> true end
               )

      # Target as atom
      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dsg_atom",
        asset_url: "https://uploads.linear.app/dsg_atom/still_a.png",
        asset_id: "ast_dsg_atom"
      )

      assert {:ok, %Design{}} =
               Artifacts.capture_design(scope, :tsk_dsg_atom, dir,
                 project: project,
                 url_probe: fn _url -> true end
               )
    end

    test "handles upload error, comment error, and unreadable still file", %{
      dir: dir,
      issue: issue,
      project: project
    } do
      scope = Scope.for_system()
      ArtifactHelpers.write_design_manifest(dir)

      # Still file unreadable before upload
      still_file = Path.join(dir, "still_a.png")
      File.chmod!(still_file, 0o000)

      assert {:error, msg} =
               Artifacts.capture_design(scope, "tsk_unreadable_still", dir,
                 project: project,
                 url_probe: fn _url -> true end
               )

      assert msg =~ "Failed to read design still"
      File.chmod!(still_file, 0o644)

      # Upload error
      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Upload service unavailable")
      end)

      assert {:error, _reason} =
               Artifacts.capture_design(scope, "tsk_dsg_up_err", dir,
                 project: project,
                 url_probe: fn _url -> true end
               )

      # Comment error
      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dsg_cmt_err",
        asset_url: "https://uploads.linear.app/dsg_cmt_err/still_a.png",
        asset_id: "ast_dsg_cmt_err"
      )

      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Comment failed")
      end)

      assert {:error, _reason} =
               Artifacts.capture_design(scope, "tsk_dsg_cmt_err", dir,
                 issue: issue,
                 project: project,
                 url_probe: fn _url -> true end
               )
    end

    test "returns error when manifest does not exist in target path", %{dir: dir, project: project} do
      scope = Scope.for_system()
      empty_dir = Path.join(dir, "empty_sub")
      File.mkdir_p!(empty_dir)

      assert {:error, msg} =
               Artifacts.capture_design(scope, "tsk_missing_manifest", empty_dir,
                 project: project,
                 url_probe: fn _url -> true end
               )

      assert msg =~ "No design manifest found at"
    end
  end
end
