defmodule Rail.Issues.Actions.AddTestingImageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
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
    scope = user_scope(project_ids: [project.id])
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: waiting, scope: scope, project: project}
  end

  test "a picture is stored in R2, added after the others and moves a Waiting ticket to In testing", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    Req.Test.expect(R2, 2, fn conn ->
      assert ["image/png"] = Plug.Conn.get_req_header(conn, "content-type")
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, %Issue{testing_state: :testing, testing_images: [%TestingImage{name: "first.png", url: first}]}} =
             Issues.add_testing_image(scope, issue, "first.png", "PNG_BYTES")

    assert first =~ ~r/\/issues\/#{issue_id}\/assets\/[0-9a-f-]{36}-first\.png\z/
    assert_received {:testing_notes_changed, ^issue_id}
    assert_received {:issue_changed, ^issue_id}

    assert {:ok, %Issue{testing_images: [%TestingImage{url: ^first}, %TestingImage{name: "second.PNG"}]}} =
             Issues.add_testing_image(scope, issue, "second.PNG", "PNG_BYTES")

    refute_received {:issue_changed, ^issue_id}
  end

  test "refuses a file that is not a picture, a ticket out of the queue and a project the user cannot open", %{
    issue: issue,
    scope: scope
  } do
    assert {:error, :not_accepted} = Issues.add_testing_image(scope, issue, "notes.pdf", "PDF")
    assert {:error, :not_found} = Issues.add_testing_image(user_scope(), issue, "shot.png", "PNG")

    {:ok, tested} = Issues.mark_issue_tested(scope, issue)
    assert {:error, :testing_finished} = Issues.add_testing_image(scope, tested, "shot.png", "PNG")
  end

  test "a ticket finished while its picture was stored keeps nothing", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    Req.Test.expect(R2, fn conn ->
      {:ok, _tested} = Issues.mark_issue_tested(scope, issue)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:error, :testing_finished} = Issues.add_testing_image(scope, issue, "shot.png", "PNG")
    assert %Issue{testing_images: []} = Repo.get!(Issue, issue_id)
  end

  test "a ticket deleted while its picture was stored finds nothing", %{issue: issue, scope: scope} do
    Req.Test.expect(R2, fn conn ->
      Repo.delete!(issue)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:error, :not_found} = Issues.add_testing_image(scope, issue, "shot.png", "PNG")
  end
end
