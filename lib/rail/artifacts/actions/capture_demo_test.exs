defmodule Rail.Artifacts.Actions.CaptureDemoTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_capture_demo"

  setup do
    dir = Path.join(@tmp_base, "demo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ws = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws.id})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_demo_iss"})

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, project: project, issue: issue, ws: ws}
  end

  describe "capture_demo/4" do
    test "rejects unauthorized scope", %{dir: dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.capture_demo(scope, "tsk_1", dir)
    end

    test "captures recorded demo with frame upload and comment creation", %{
      dir: dir,
      issue: issue,
      project: project
    } do
      scope = Scope.for_system()
      owner = Repo.insert!(User.factory())
      ArtifactHelpers.write_demo_manifest(dir)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_1",
        asset_url: "https://uploads.linear.app/dmo_1/ac1-0.png",
        asset_id: "ast_dmo_1"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "lin_cmt_demo_1",
        "body" => "Demo comment"
      })

      assert {:ok,
              %Demo{
                version: 1,
                outcome: "recorded",
                linear_comment_id: "lin_cmt_demo_1",
                segments: [
                  %DemoSegment{
                    frames: [
                      %DemoFrame{
                        url: "https://uploads.linear.app/dmo_1/ac1-0.png",
                        linear_asset_id: "ast_dmo_1"
                      }
                    ]
                  }
                ]
              }} =
               Artifacts.capture_demo(scope, "tsk_demo_cap_1", dir,
                 issue: issue,
                 owner_user: owner,
                 project: project
               )

      # Verify next capture auto-increments version
      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_2",
        asset_url: "https://uploads.linear.app/dmo_2/ac1-0.png",
        asset_id: "ast_dmo_2"
      )

      assert {:ok, %Demo{version: 2}} =
               Artifacts.capture_demo(scope, "tsk_demo_cap_1", dir, project: project)
    end

    test "captures declined demo without frames", %{dir: dir} do
      scope = Scope.user_scope()

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "outcome" => "declined",
          "note" => "No UI touched",
          "version" => 1
        })
      )

      assert {:ok, %Demo{outcome: "declined", version: 1, note: "No UI touched", segments: []}} =
               Artifacts.capture_demo(scope, "tsk_declined", dir)
    end

    test "propagates validator failure", %{dir: dir} do
      scope = Scope.for_system()
      File.write!(Path.join(dir, "manifest.json"), "{invalid")

      assert {:error, msg} = Artifacts.capture_demo(scope, "tsk_err", dir)
      assert msg =~ "Failed to parse demo manifest"
    end

    test "handles subfolder demo, keyword list args, and target types", %{
      dir: dir,
      project: project
    } do
      scope = Scope.for_system()
      demo_sub = Path.join(dir, "demo")
      File.mkdir_p!(demo_sub)
      ArtifactHelpers.write_demo_manifest(demo_sub)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_sub",
        asset_url: "https://uploads.linear.app/dmo_sub/ac1-0.png",
        asset_id: "ast_dmo_sub"
      )

      # Target as struct, dir as parent with subfolder demo, opts as 3rd arg
      assert {:ok, %Demo{}} =
               Artifacts.capture_demo(scope, %{id: "tsk_demo_struct"}, scratch_dir: dir, project: project)

      # Target as atom
      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_atom",
        asset_url: "https://uploads.linear.app/dmo_atom/ac1-0.png",
        asset_id: "ast_dmo_atom"
      )

      assert {:ok, %Demo{}} =
               Artifacts.capture_demo(scope, :tsk_demo_atom, dir, project: project)
    end

    test "handles upload error, comment error, and missing frame file", %{
      dir: dir,
      issue: issue,
      project: project
    } do
      scope = Scope.for_system()
      ArtifactHelpers.write_demo_manifest(dir)

      # Frame file unreadable before upload
      frame_file = Path.join(dir, "ac1-0.png")
      File.chmod!(frame_file, 0o000)
      assert {:error, msg} = Artifacts.capture_demo(scope, "tsk_unreadable_frame", dir, project: project)
      assert msg =~ "Failed to read demo frame"
      File.chmod!(frame_file, 0o644)

      # Re-write manifest and frame
      ArtifactHelpers.write_demo_manifest(dir)

      # Upload error
      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Upload service unavailable")
      end)

      assert {:error, _reason} = Artifacts.capture_demo(scope, "tsk_up_err", dir, project: project)

      # Comment error
      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_cmt_err",
        asset_url: "https://uploads.linear.app/dmo_cmt_err/ac1-0.png",
        asset_id: "ast_dmo_cmt_err"
      )

      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Comment failed")
      end)

      assert {:error, _reason} =
               Artifacts.capture_demo(scope, "tsk_cmt_err", dir,
                 issue: issue,
                 project: project
               )
    end

    test "handles unfilmable segment in recorded demo", %{dir: dir, project: project} do
      scope = Scope.for_system()

      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Recorded part",
            "outcome" => "recorded",
            "frames" => [%{"path" => "ac1-0.png", "holdMs" => 500}]
          },
          %{
            "criterionIndex" => 2,
            "criterion" => "Worker job",
            "outcome" => "not_filmable",
            "note" => "Background job"
          }
        ]
      })

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_unf",
        asset_url: "https://uploads.linear.app/dmo_unf/ac1-0.png",
        asset_id: "ast_dmo_unf"
      )

      assert {:ok,
              %Demo{
                segments: [
                  %DemoSegment{outcome: :recorded},
                  %DemoSegment{outcome: :not_filmable}
                ]
              }} =
               Artifacts.capture_demo(scope, "tsk_unfilmable", dir, project: project)
    end

    test "rejects non-scope caller", %{dir: dir} do
      assert {:error, :not_authorized} = Artifacts.capture_demo(:not_a_scope, "tsk_1", dir)
    end

    test "falls back to demo directory when no manifest exists in target", %{dir: dir} do
      scope = Scope.for_system()
      empty_target = Path.join(dir, "no_manifest_sub")
      File.mkdir_p!(empty_target)

      assert {:error, msg} = Artifacts.capture_demo(scope, "tsk_missing_manifest", empty_target)
      assert msg =~ "Demo manifest not found"
    end

    test "resolves owner_user from task.owner_user_id when posting comment", %{
      dir: dir,
      project: project,
      issue: issue
    } do
      scope = Scope.for_system()
      owner = Repo.insert!(User.factory())

      task =
        create_test_task(%{
          project_id: project.id,
          issue_id: issue.id,
          owner_user_id: owner.id
        })

      ArtifactHelpers.write_demo_manifest(dir)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_owner",
        asset_url: "https://uploads.linear.app/dmo_owner/ac1-0.png",
        asset_id: "ast_dmo_owner"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "lin_cmt_demo_owner",
        "body" => "Demo comment"
      })

      assert {:ok, %Demo{linear_comment_id: "lin_cmt_demo_owner"}} =
               Artifacts.capture_demo(scope, task, dir, project: project)
    end
  end
end
