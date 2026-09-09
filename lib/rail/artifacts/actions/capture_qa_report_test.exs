defmodule Rail.Artifacts.Actions.CaptureQaReportTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.Embeds.QaArtifact
  alias Rail.Domain.Embeds.QaRow
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_capture_qa"

  setup do
    dir = Path.join(@tmp_base, "qa_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ws = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws.id})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_qa_iss"})

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, project: project, issue: issue, ws: ws}
  end

  describe "capture_qa_report/4" do
    test "rejects unauthorized scope", %{dir: dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.capture_qa_report(scope, "tsk_1", dir)
    end

    test "captures QA report with image artifact upload and comment creation", %{
      dir: dir,
      issue: issue,
      project: project
    } do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(dir)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_1",
        asset_url: "https://uploads.linear.app/qa_1/screenshot.png",
        asset_id: "ast_qa_1"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "lin_cmt_qa_1",
        "body" => "QA comment"
      })

      assert {:ok,
              %QaReport{
                task_id: "tsk_qa_cap_1",
                role_run_id: "rr_abc",
                commit: "abc1234",
                rows: [
                  %QaRow{
                    artifacts: [
                      %QaArtifact{
                        name: "screenshot.png",
                        url: "https://uploads.linear.app/qa_1/screenshot.png"
                      }
                    ]
                  }
                ]
              }} =
               Artifacts.capture_qa_report(scope, "tsk_qa_cap_1", dir,
                 issue: issue,
                 project: project,
                 role_run_id: "rr_abc"
               )
    end

    test "propagates validator failure", %{dir: dir} do
      scope = Scope.for_system()
      File.write!(Path.join(dir, "manifest.json"), "{invalid")

      assert {:error, msg} = Artifacts.capture_qa_report(scope, "tsk_err", dir)
      assert msg =~ "Failed to parse QA manifest"
    end

    test "handles subfolder qa, keyword list args, and user/atom target", %{
      dir: dir,
      project: project
    } do
      scope = Scope.user_scope()
      qa_sub = Path.join(dir, "qa")
      File.mkdir_p!(qa_sub)
      ArtifactHelpers.write_qa_manifest(qa_sub)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_sub",
        asset_url: "https://uploads.linear.app/qa_sub/screenshot.png",
        asset_id: "ast_qa_sub"
      )

      # Target as struct, dir as parent with subfolder qa, opts as 3rd arg
      assert {:ok, %QaReport{}} =
               Artifacts.capture_qa_report(scope, %{id: "tsk_qa_struct"}, scratch_dir: dir, project: project)

      # Target as atom
      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_atom",
        asset_url: "https://uploads.linear.app/qa_atom/screenshot.png",
        asset_id: "ast_qa_atom"
      )

      assert {:ok, %QaReport{}} =
               Artifacts.capture_qa_report(scope, :tsk_qa_atom, dir, project: project)
    end

    test "handles upload error and unreadable artifact file", %{
      dir: dir,
      issue: issue,
      project: project
    } do
      scope = Scope.for_system()

      ArtifactHelpers.write_qa_manifest(dir, %{
        "session" => %{},
        "rows" => [
          %{
            "id" => "c1",
            "check" => "Check 1",
            "result" => "pass",
            "severity" => "blocker",
            "artifacts" => [%{"name" => "screenshot.png", "kind" => "image", "path" => "screenshot.png"}]
          },
          %{
            "id" => "c2",
            "check" => "Check 2",
            "result" => "pass",
            "severity" => "minor",
            "artifacts" => [%{"name" => "log.txt", "kind" => "text", "text" => "log output"}]
          }
        ]
      })

      # Upload error
      Req.Test.expect(Rail.Linear, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Upload service unavailable")
      end)

      assert {:error, _reason} =
               Artifacts.capture_qa_report(scope, "tsk_qa_up_err", dir, project: project)

      # Unreadable image file before upload (gracefully leaves art without url)
      img_file = Path.join(dir, "screenshot.png")
      File.chmod!(img_file, 0o000)

      LinearMock.mock_create_comment_success(%{"id" => "lin_cmt_unreadable", "body" => "QA"})

      assert {:ok, %QaReport{rows: [_r1, _r2]}} =
               Artifacts.capture_qa_report(scope, "tsk_qa_unreadable", dir,
                 issue: issue,
                 project: project
               )

      File.chmod!(img_file, 0o644)
    end
  end
end
