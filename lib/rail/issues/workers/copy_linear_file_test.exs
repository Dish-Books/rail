defmodule Rail.Issues.Workers.CopyLinearFileTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.LinearFileCopy
  alias Rail.Issues.Workers.CopyLinearFile
  alias Rail.Issues.Workers.MoveToLocalTracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @url "https://uploads.linear.app/org/a1/demo.mp4"

  setup do
    project =
      Repo.insert!(%Project{
        name: "Copy Project",
        github_repo: "org/copy-project",
        github_installation_id: 1,
        default_branch: "main",
        key: "CPY",
        linear_team_id: "lin_team_cpy",
        linear_workspace_id: "lw_test_seed",
        clone_path: "/tmp/repos/copy-project"
      })

    copy =
      Repo.insert!(%LinearFileCopy{
        project_id: project.id,
        issue_external_id: "lin_1",
        issue_id: "iss_copy_1",
        identifier: "CPY-1",
        url: @url
      })

    Req.Test.stub(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("video/mp4") |> Plug.Conn.send_resp(200, "VIDEO")
    end)

    Req.Test.stub(R2, &Plug.Conn.send_resp(&1, 200, ""))

    %{project: project, copy: copy}
  end

  test "copies the file under its ticket's Rail id, and the last file queues the move", %{
    project: %Project{id: project_id},
    copy: copy
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "tracker_moves")

    assert :ok = perform_job(CopyLinearFile, %{copy_id: copy.id, project_id: project_id})

    assert %LinearFileCopy{state: :copied, copied_url: copied_url} = Repo.get!(LinearFileCopy, copy.id)
    assert copied_url =~ ~r"/issues/iss_copy_1/assets/[0-9a-f-]{36}-demo\.mp4\z"
    assert_enqueued(worker: MoveToLocalTracker, args: %{project_id: project_id})
    assert_receive {:tracker_move_progress, ^project_id}
  end

  test "a file another is still waiting beside leaves the move unqueued", %{project: project, copy: copy} do
    Repo.insert!(%LinearFileCopy{
      project_id: project.id,
      issue_external_id: "lin_2",
      issue_id: "iss_copy_2",
      url: "https://uploads.linear.app/org/a2/other.png"
    })

    assert :ok = perform_job(CopyLinearFile, %{copy_id: copy.id, project_id: project.id})
    refute_enqueued(worker: MoveToLocalTracker)
  end

  test "a file already settled, or no longer recorded, is left alone", %{project: project, copy: copy} do
    Repo.update_all(from(c in LinearFileCopy, where: c.id == ^copy.id), set: [state: :copied])
    Req.Test.stub(Rail.Linear, fn _conn -> flunk("fetched a settled file") end)

    assert :ok = perform_job(CopyLinearFile, %{copy_id: copy.id, project_id: project.id})
    assert :ok = perform_job(CopyLinearFile, %{copy_id: "lfc_missing", project_id: project.id})
  end

  test "a timeout is tried again, and on the last try the file waits as failed, naming it", %{
    project: project,
    copy: copy
  } do
    Req.Test.stub(R2, &Req.Test.transport_error(&1, :timeout))

    assert {:error, _timeout} = perform_job(CopyLinearFile, %{copy_id: copy.id, project_id: project.id}, attempt: 1)
    assert %LinearFileCopy{state: :pending, error: nil} = Repo.get!(LinearFileCopy, copy.id)

    assert {:error, _timeout} = perform_job(CopyLinearFile, %{copy_id: copy.id, project_id: project.id}, attempt: 5)

    error = "Copying a file on CPY-1 (#{@url}) stopped (timeout) after 5 tries."
    assert %LinearFileCopy{state: :failed, error: ^error} = Repo.get!(LinearFileCopy, copy.id)
    refute_enqueued(worker: MoveToLocalTracker)
  end

  test "Linear's rate limit is tried again, and a project with no Linear token fails the file at once", %{
    project: project,
    copy: copy
  } do
    # Req tries a 429 again itself first, at once when Linear says so.
    Req.Test.stub(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "0") |> Plug.Conn.send_resp(429, "Slow down")
    end)

    assert {:error, {:linear_api_error, 429, _body}} =
             perform_job(CopyLinearFile, %{copy_id: copy.id, project_id: project.id}, attempt: 1)

    assert %LinearFileCopy{state: :pending} = Repo.get!(LinearFileCopy, copy.id)

    Repo.update_all(from(p in Project, where: p.id == ^project.id), set: [linear_workspace_id: nil])

    assert {:cancel, :no_workspace_token} =
             perform_job(CopyLinearFile, %{copy_id: copy.id, project_id: project.id}, attempt: 1)

    assert %LinearFileCopy{state: :failed, error: "Rail has no Linear token for this project's workspace."} =
             Repo.get!(LinearFileCopy, copy.id)
  end
end
