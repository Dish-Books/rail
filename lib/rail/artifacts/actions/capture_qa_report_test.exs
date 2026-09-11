defmodule Rail.Artifacts.Actions.CaptureQaReportTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.Embeds.QaArtifact
  alias Rail.Domain.Embeds.QaRow
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_capture_qa"

  setup do
    dir = Path.join(@tmp_base, "qa_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, ws} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Capture QA Workspace 12302",
        external_id: "lin_ws_capture_qa_12302",
        token: "lin_api_token_capture_qa_12302",
        webhook_secret: "whsec_capture_qa_12302"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Capture QA Project 12303",
        github_repo: "org/capture-qa-12303",
        github_installation_id: 12_303,
        linear_team_id: "team_capture_qa_12303",
        linear_team_key: "P12303",
        clone_path: "/tmp/repos/capture-qa-12303",
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
      "id" => "lin_qa_iss",
      "identifier" => "ISS-12304",
      "title" => "Capture QA Issue 12304"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Capture QA Issue 12304")

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

    test "reads text artifact content from file on disk and captures from worktree .rail/qa", %{
      dir: dir,
      project: project
    } do
      scope = Scope.for_system()
      rail_qa = Path.join([dir, ".rail", "qa"])
      File.mkdir_p!(rail_qa)

      log_path = Path.join(rail_qa, "system_check.txt")
      File.write!(log_path, "TEST_SYSTEM_LOG_CONTENT")

      ArtifactHelpers.write_qa_manifest(rail_qa, %{
        "commit" => "wt_commit",
        "session" => %{"pid" => 1234},
        "rows" => [
          %{
            "id" => "c_txt",
            "check" => "Check text read",
            "result" => "pass",
            "severity" => "cosmetic",
            "artifacts" => [
              %{"name" => "system_check.txt", "kind" => "text", "path" => "system_check.txt"}
            ]
          }
        ]
      })

      assert {:ok,
              %QaReport{
                commit: "wt_commit",
                rows: [
                  %QaRow{
                    artifacts: [
                      %QaArtifact{name: "system_check.txt", kind: :text, text: "TEST_SYSTEM_LOG_CONTENT"}
                    ]
                  }
                ]
              }} = Artifacts.capture_qa_report(scope, "tsk_wt_qa", dir, project: project)
    end

    test "resolves issue and owner_user from task associations when posting Linear comment", %{
      dir: dir,
      project: project,
      issue: issue
    } do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(dir)

      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_capture_qa_12305",
          login: "capture_qa_user_12305",
          email: "capture_qa_user_12305@example.com",
          github_token: "gho_token_12305"
        })

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_capture_qa_12306",
        "identifier" => "TSK-12306",
        "title" => "Task 12306"
      })

      {:ok, issue_12306} = Issues.capture_issue(system_scope(), project, "Task 12306")

      {:ok, %Rail.Pipeline.Schemas.Task{id: _task_id} = task} = Pipeline.create_task(issue_12306, :product)

      {:ok, %Rail.Pipeline.Schemas.Task{id: task_id} = task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: issue.id,
          owner_user_id: user.id
        })

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_task",
        asset_url: "https://uploads.linear.app/qa_task/screenshot.png",
        asset_id: "ast_qa_task"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "lin_cmt_task",
        "body" => "QA Comment"
      })

      # Pass Task struct without explicit :issue or :owner_user opts
      assert {:ok, %QaReport{task_id: ^task_id}} =
               Artifacts.capture_qa_report(scope, task, dir, project: project)

      # Also test with preloaded associations
      task_preloaded = Repo.preload(task, issue: :owner_user)

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_preloaded",
        asset_url: "https://uploads.linear.app/qa_preloaded/screenshot.png",
        asset_id: "ast_qa_preloaded"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "lin_cmt_preloaded",
        "body" => "QA Comment"
      })

      assert {:ok, %QaReport{task_id: ^task_id}} =
               Artifacts.capture_qa_report(scope, task_preloaded, dir, project: project)
    end

    test "resolves project from preloaded task association", %{
      dir: dir,
      project: project
    } do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(dir)

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_capture_qa_12307",
        "identifier" => "TSK-12307",
        "title" => "Task 12307"
      })

      {:ok, issue_12307} = Issues.capture_issue(system_scope(), project, "Task 12307")

      {:ok, %Rail.Pipeline.Schemas.Task{id: task_id} = task} = Pipeline.create_task(issue_12307, :product)

      task_with_proj = %{task | project: project}

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_proj_test",
        asset_url: "https://uploads.linear.app/qa_proj_test/screenshot.png",
        asset_id: "ast_qa_proj_test"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "cmt_qa_proj_test",
        "body" => "QA report",
        "createdAt" => "2026-09-05T12:00:00.000Z"
      })

      assert {:ok, %QaReport{task_id: ^task_id}} =
               Artifacts.capture_qa_report(scope, task_with_proj, dir)
    end

    test "returns error when manifest is not found in directory or subdirectories", %{
      dir: dir
    } do
      scope = Scope.for_system()
      empty_dir = Path.join(dir, "empty_sub")
      File.mkdir_p!(empty_dir)

      assert {:error, msg} = Artifacts.capture_qa_report(scope, "tsk_missing", empty_dir)
      assert msg =~ "QA manifest not found at"
    end

    test "captures QA report with image artifact that already has URL and no local path", %{
      dir: dir,
      project: project
    } do
      scope = Scope.for_system()

      ArtifactHelpers.write_qa_manifest(dir, %{
        "rows" => [
          %{
            "id" => "check_url_only",
            "check" => "Check with existing URL",
            "result" => "pass",
            "severity" => "cosmetic",
            "artifacts" => [
              %{
                "name" => "remote.png",
                "kind" => "image",
                "url" => "https://example.com/remote.png"
              }
            ]
          }
        ]
      })

      assert {:ok,
              %QaReport{
                rows: [
                  %QaRow{
                    artifacts: [
                      %QaArtifact{
                        name: "remote.png",
                        url: "https://example.com/remote.png"
                      }
                    ]
                  }
                ]
              }} = Artifacts.capture_qa_report(scope, "tsk_remote_img", dir, project: project)
    end

    test "posts Linear comment using explicit owner_user opt", %{
      dir: dir,
      project: project,
      issue: issue
    } do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(dir)

      {:ok, user} =
        Users.register_oauth_user(%{
          github_id: "gh_capture_qa_12308",
          login: "capture_qa_user_12308",
          email: "capture_qa_user_12308@example.com",
          github_token: "gho_token_12308"
        })

      LinearMock.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_owner_opt",
        asset_url: "https://uploads.linear.app/qa_owner_opt/screenshot.png",
        asset_id: "ast_qa_owner_opt"
      )

      LinearMock.mock_create_comment_success(%{
        "id" => "lin_cmt_owner_opt",
        "body" => "QA Comment"
      })

      assert {:ok, %QaReport{}} =
               Artifacts.capture_qa_report(scope, "tsk_explicit_owner", dir,
                 project: project,
                 issue: issue,
                 owner_user: user
               )
    end
  end
end
