defmodule Rail.Issues.Actions.ImportIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Users

  test "an issue Rail already has comes back without asking Linear", %{project: project} do
    %Issue{id: issue_id} =
      Repo.insert!(%Issue{
        project_id: project.id,
        external_id: "lin_imp_have",
        identifier: "TST-401",
        title: "Have",
        state: :todo
      })

    assert {:ok, %Issue{id: ^issue_id}} = Issues.import_issue(project, "TST-401")
  end

  test "a ticket on the project's team is fetched and stored as Linear has it", %{project: %{id: project_id} = project} do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_imp", login: "imp", email: "imp@example.com"})

    user |> Ecto.Changeset.change(linear_user_id: "lin_user_imp") |> Repo.update!()
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    Req.Test.expect(Rail.Linear, fn conn ->
      assert %{"variables" => %{"id" => "TST-402"}} = conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{
        "data" => %{
          "issue" => %{
            "id" => "lin_imp_new",
            "identifier" => "TST-402",
            "title" => "Wait times",
            "description" => "Rows show no wait.",
            "priority" => 2,
            "assignee" => %{"id" => "lin_user_imp"},
            "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"},
            "url" => "https://linear.app/acme/issue/TST-402",
            "team" => %{"id" => "lin_team_id"}
          }
        }
      })
    end)

    assert {:ok,
            %Issue{
              id: issue_id,
              project_id: ^project_id,
              external_id: "lin_imp_new",
              title: "Wait times",
              state: :done,
              priority: :high,
              owner_user_id: ^user_id,
              url: "https://linear.app/acme/issue/TST-402"
            }} = Issues.import_issue(project, "TST-402")

    assert_received {:issue_changed, ^issue_id}
    refute_enqueued(worker: SyncIssue)
  end

  test "a ticket on another team, or none at all, is not found", %{project: project} do
    Req.Test.expect(Rail.Linear, 2, fn conn ->
      case conn |> Req.Test.raw_body() |> Jason.decode!() do
        %{"variables" => %{"id" => "OPS-1"}} ->
          Req.Test.json(conn, %{
            "data" => %{
              "issue" => %{"id" => "lin_ops_1", "identifier" => "OPS-1", "title" => "Ops", "team" => %{"id" => "lin_ops"}}
            }
          })

        %{"variables" => %{"id" => "TST-999"}} ->
          Req.Test.json(conn, %{"errors" => [%{"message" => "Entity not found"}]})
      end
    end)

    assert {:error, :not_found} = Issues.import_issue(project, "OPS-1")
    assert {:error, :not_found} = Issues.import_issue(project, "TST-999")
    refute Repo.get_by(Issue, external_id: "lin_ops_1")
  end

  test "Linear failing is passed on", %{project: project} do
    Req.Test.expect(Rail.Linear, &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{})))

    assert {:error, {:linear_api_error, 500, _body}} = Issues.import_issue(project, "TST-403")
  end
end
