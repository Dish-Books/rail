defmodule Rail.Issues.Actions.AddTestingImageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects

  setup {Req.Test, :verify_on_exit!}

  setup do
    key = "Ati#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Pictures",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Export keeps icons"})
    {:ok, waiting} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    failed = %{TestingScenario.agent("Six icons fit") | result: :failed}
    other = TestingScenario.agent("Seven wrap")
    {:ok, written} = waiting |> Issue.testing_scenarios_changeset([failed, other], :agent) |> Repo.update()
    scope = user_scope(project_ids: [project.id])
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: written, failed: failed, scope: scope, project: project}
  end

  test "a picture is stored in R2, added to its scenario after the others and moves a Waiting ticket to In testing", %{
    issue: %Issue{id: issue_id} = issue,
    failed: %{id: failed_id},
    scope: scope
  } do
    Req.Test.expect(R2, 2, fn conn ->
      assert ["image/png"] = Plug.Conn.get_req_header(conn, "content-type")
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok,
            %Issue{
              testing_state: :testing,
              testing_images: [],
              testing_scenarios: [
                %TestingScenario{id: ^failed_id, images: [%TestingImage{name: "first.png", url: first}]},
                %TestingScenario{images: []}
              ]
            }} = Issues.add_testing_image(scope, issue, failed_id, "first.png", "PNG_BYTES")

    assert first =~ ~r/\/issues\/#{issue_id}\/assets\/[0-9a-f-]{36}-first\.png\z/
    assert_received {:testing_changed, ^issue_id}
    assert_received {:issue_changed, ^issue_id}

    assert {:ok,
            %Issue{
              testing_scenarios: [
                %TestingScenario{images: [%TestingImage{url: ^first}, %TestingImage{name: "second.PNG"}]},
                _other
              ]
            }} = Issues.add_testing_image(scope, issue, failed_id, "second.PNG", "PNG_BYTES")

    assert %Issue{testing_scenarios: [%TestingScenario{images: [_first, _second]}, _other]} = Repo.get!(Issue, issue_id)
    refute_received {:issue_changed, ^issue_id}
  end

  test "refuses a file that is not a picture, a ticket out of the queue and a project the user cannot open", %{
    issue: issue,
    failed: %{id: failed_id},
    scope: scope
  } do
    assert {:error, :not_accepted} = Issues.add_testing_image(scope, issue, failed_id, "notes.pdf", "PDF")
    assert {:error, :not_found} = Issues.add_testing_image(user_scope(), issue, failed_id, "shot.png", "PNG")

    {:ok, reopened} =
      Issues.set_issue_status(system_scope(), issue, %{id: "in_progress", name: "In Progress", state: :in_progress})

    assert {:error, :testing_finished} = Issues.add_testing_image(scope, reopened, failed_id, "shot.png", "PNG")
  end

  test "a ticket being written refuses before anything is stored", %{
    issue: issue,
    failed: %{id: failed_id},
    scope: scope
  } do
    {:ok, requested} = Issues.request_test_scenarios(issue, "abc123")
    assert {:error, :writing_scenarios} = Issues.add_testing_image(scope, requested, failed_id, "shot.png", "PNG")
  end

  test "a ticket asked for scenarios while its picture was stored keeps nothing", %{
    issue: %Issue{id: issue_id} = issue,
    failed: %{id: failed_id},
    scope: scope
  } do
    Req.Test.expect(R2, fn conn ->
      {:ok, _requested} = Issues.request_test_scenarios(issue, "abc123")
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:error, :writing_scenarios} = Issues.add_testing_image(scope, issue, failed_id, "shot.png", "PNG")
    assert %Issue{testing_scenarios: [%TestingScenario{images: []}, _other]} = Repo.get!(Issue, issue_id)
  end

  test "a scenario removed while its picture was stored finds nothing", %{
    issue: issue,
    failed: %{id: failed_id},
    scope: scope
  } do
    Req.Test.expect(R2, fn conn ->
      {:ok, _removed} = Issues.remove_testing_scenario(scope, issue, failed_id)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:error, :not_found} = Issues.add_testing_image(scope, issue, failed_id, "shot.png", "PNG")
  end

  test "a ticket deleted while its picture was stored finds nothing", %{
    issue: issue,
    failed: %{id: failed_id},
    scope: scope
  } do
    Req.Test.expect(R2, fn conn ->
      Repo.delete!(issue)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:error, :not_found} = Issues.add_testing_image(scope, issue, failed_id, "shot.png", "PNG")
  end
end
