defmodule Rail.Tools.Actions.GetBrowserFrameTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Tools

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Browser Frame Project",
        github_repo: "org/browser-frame",
        github_installation_id: 47_047,
        linear_workspace: %{
          name: "Browser Frame Workspace",
          external_id: "lin_ws_browser_frame",
          token: "lin_api_token_browser_frame",
          webhook_secret: "whsec_browser_frame"
        },
        linear_team_key: "BFR",
        default_branch: "main",
        clone_path: "/tmp/repos/browser-frame",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_bfr_1", "identifier" => "BFR-1", "title" => "Browser Frame"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Browser Frame"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  # Every QA panel asks for this on the way in, including the ones opened long
  # after the pass ended, so no browser is the ordinary case rather than an error.
  test "a task with no browser has nothing to show", %{task: task} do
    assert Tools.get_browser_frame(task) == nil
  end
end
