defmodule RailWeb.Mcp.Tools.ListFindingsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Users

  setup do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    key = "MLF#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Reviewed",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "mlf_#{key}", login: "mlf_#{key}", name: "Mlf", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Reviewed", owner_user_id: user.id})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    shot = Path.join([task.scratch_path, "qa", "shots", "send-twice.png"])
    File.mkdir_p!(Path.dirname(shot))
    File.write!(shot, "png bytes")

    {:ok, finding} =
      Pipeline.save_finding(task, %{
        key: "send-twice",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Send posts twice",
        problem: "A second click posts the comment again.",
        file: "lib/send.ex",
        line: 12,
        end_line: 14,
        fix: "Disable Send until the server answers.",
        why: "Two posts confuse the thread.",
        rule: "A second click does nothing harmful.",
        severity: :major,
        recommendation: :fix,
        places: [%{file: "lib/send.ex", line: 12, end_line: 14}],
        evidence: [
          %{name: "The handler", kind: :code, file: "lib/send.ex", line: 12, end_line: 14},
          %{name: "Two comments", kind: :screenshot, path: "shots/send-twice.png"}
        ]
      })

    {:ok, %{round: 1}} = Pipeline.save_review(task)
    %{project: project, user: user, issue: issue, task: task, finding: finding, scope: Rail.Scope.for_user(user)}
  end

  test "a finding nobody ruled shows its problem, place, evidence and history, and the recommendation apart", %{
    issue: %{identifier: identifier},
    task: task,
    finding: %{updated_at: updated_at},
    scope: scope
  } do
    version = "1@#{DateTime.to_iso8601(updated_at)}"
    shot_url = RailWeb.Endpoint.url() <> "/tasks/#{task.id}/findings/send-twice/evidence/1"

    assert {:ok,
            %{
              "identifier" => ^identifier,
              "stage" => "Review",
              "findings" => [
                %{
                  "key" => "send-twice",
                  "version" => ^version,
                  "title" => "Send posts twice",
                  "kind" => "code",
                  "severity" => "major",
                  "round" => 1,
                  "status" => "open",
                  "suppressed" => false,
                  "where" => "lib/send.ex:12-14",
                  "places" => ["lib/send.ex:12-14"],
                  "problem" => "A second click posts the comment again.",
                  "fix" => "Disable Send until the server answers.",
                  "rule" => "A second click does nothing harmful.",
                  "recommendation" => %{"decision" => "fix", "why" => "Two posts confuse the thread."},
                  "ruling" => nil,
                  "filed_as" => nil,
                  "evidence" => [
                    %{"name" => "The handler", "kind" => "code", "where" => "lib/send.ex:12-14"},
                    %{"name" => "Two comments", "kind" => "screenshot", "url" => ^shot_url, "text" => nil}
                  ],
                  "history" => [%{"round" => 1, "kind" => "raised", "by" => nil, "decision" => nil}]
                }
              ]
            }} = call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})
  end

  test "a ruled finding names its ruling and who made it, in the ruling and its history", %{
    issue: %{identifier: identifier},
    user: %{login: login},
    finding: finding,
    scope: scope
  } do
    {:ok, _ruled} = Pipeline.decide_finding(scope, finding, :skip)

    assert {:ok,
            %{
              "findings" => [
                %{
                  "recommendation" => %{"decision" => "fix"},
                  "ruling" => %{"decision" => "dont_fix", "by" => ^login},
                  "history" => [%{"kind" => "raised"}, %{"kind" => "ruling", "decision" => "dont_fix", "by" => ^login}]
                }
              ]
            }} = call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})
  end

  test "a round that opens while the findings are read gives nothing, and the next read names the new round", %{
    issue: %{identifier: identifier},
    scope: scope
  } do
    stub(Pipeline, :list_findings, fn task -> call_original(Pipeline, :list_findings, [task]) end)

    expect(Pipeline, :list_findings, fn task ->
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      call_original(Pipeline, :list_findings, [task])
    end)

    assert {:error,
            "A new review round opened while Rail read the findings, so it returned nothing and saved nothing. " <>
              "Read them again with list_findings."} =
             call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    assert {:ok, %{"findings" => [%{"key" => "send-twice", "version" => "2@" <> _updated_at}]}} =
             call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})
  end

  test "a ticket out of reach is no such ticket, and one with no task says so", %{
    project: project,
    issue: %{identifier: identifier},
    scope: scope
  } do
    assert {:error, "No ticket " <> _rest} =
             call_mcp_tool(user_scope(project_ids: []), "list_findings", %{"identifier" => identifier})

    {:ok, %{identifier: unstarted}} = Issues.create_issue(system_scope(), project, %{title: "Never started"})

    said = "#{unstarted} has no task in Rail: it was never started, or its task was cleaned up after merging."
    assert {:error, ^said} = call_mcp_tool(scope, "list_findings", %{"identifier" => unstarted})
  end
end
