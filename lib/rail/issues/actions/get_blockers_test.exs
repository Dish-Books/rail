defmodule Rail.Issues.Actions.GetBlockersTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  setup %{project: project, github_project: github_project} do
    insert = fn target, external_id, identifier, state ->
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: target.id,
        external_id: external_id,
        identifier: identifier,
        title: "Title of #{identifier}",
        state: state
      })
      |> Repo.insert!()
      |> Map.put(:project, target)
    end

    %{
      issue: insert.(project, "lin_gb_a", "TST-10", :todo),
      held: insert.(project, "lin_gb_b", "TST-12", :todo),
      elsewhere: insert.(github_project, "lin_gb_d", "OTH-3", :in_progress)
    }
  end

  test "reads what blocks an issue and what it blocks, open blockers first, keeping only blocks relations", %{
    issue: issue,
    held: %Issue{id: held_id},
    elsewhere: %Issue{id: elsewhere_id},
    project: %{id: project_id}
  } do
    related = fn id, identifier, state_type, title ->
      %{
        "id" => id,
        "identifier" => identifier,
        "title" => title,
        "url" => "https://linear.app/issue/#{identifier}",
        "state" => %{"name" => state_type, "type" => state_type}
      }
    end

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"variables" => %{"ids" => ["lin_gb_a"]}} = Jason.decode!(body)

      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [
              %{
                "id" => "lin_gb_a",
                "relations" => %{
                  "nodes" => [
                    %{"type" => "blocks", "relatedIssue" => related.("lin_gb_e", "TST-20", "unstarted", "Waits on it")},
                    %{"type" => "related", "relatedIssue" => related.("lin_gb_x", "TST-21", "unstarted", "Related")}
                  ]
                },
                "inverseRelations" => %{
                  "nodes" => [
                    %{"type" => "blocks", "issue" => related.("lin_gb_c", "TST-11", "completed", "Finished one")},
                    %{"type" => "blocks", "issue" => related.("lin_gb_b", "TST-12", "started", "Held one")},
                    %{"type" => "blocks", "issue" => related.("lin_gb_d", "OTH-3", "started", "Secret title")},
                    %{"type" => "duplicate", "issue" => related.("lin_gb_y", "TST-22", "started", "Duplicate")}
                  ]
                }
              }
            ]
          }
        }
      })
    end)

    assert %{
             "lin_gb_a" => %{
               blocked_by: [
                 %{
                   issue: %Issue{identifier: "OTH-3", title: nil, id: ^elsewhere_id, state: :in_progress},
                   in_project: false
                 },
                 %{issue: %Issue{identifier: "TST-12", id: ^held_id, project_id: ^project_id}, in_project: true},
                 %{issue: %Issue{identifier: "TST-11", id: nil, title: nil, state: :done}, in_project: false}
               ],
               blocks: [%{issue: %Issue{identifier: "TST-20", url: "https://linear.app/issue/TST-20"}, in_project: false}]
             }
           } = Issues.get_blockers([issue, issue])
  end

  test "a project whose tracker fails adds nothing, and a GitHub one has nothing to add", %{
    issue: issue,
    elsewhere: elsewhere
  } do
    Req.Test.expect(Rail.Linear, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)

    assert %{} == Issues.get_blockers([issue, elsewhere])
  end
end
