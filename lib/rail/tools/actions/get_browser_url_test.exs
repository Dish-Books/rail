defmodule Rail.Tools.Actions.GetBrowserUrlTest do
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
        name: "Browser Url Project",
        github_repo: "org/browser-url",
        github_installation_id: 47_053,
        linear_workspace: %{
          name: "Browser Url Workspace",
          external_id: "lin_ws_browser_url",
          token: "lin_api_token_browser_url",
          webhook_secret: "whsec_browser_url"
        },
        linear_team_key: "BUR",
        default_branch: "main",
        clone_path: "/tmp/repos/browser-url",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_bur_1", "identifier" => "BUR-1", "title" => "Browser Url"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Browser Url"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  # The panel asks on every render, including for a pass that ended weeks ago, so
  # no browser is the ordinary case rather than an error.
  test "a task with no browser is nowhere", %{task: task} do
    assert Tools.get_browser_url(task) == nil
  end
end
