defmodule Rail.Pipeline.Actions.OpenPreviewTabTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Clients.Preview, as: Client
  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Tools

  setup %{project: project} do
    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        preview_enabled: true,
        preview_url_template: "https://pr-{pr_number}.preview.example.com",
        preview_login_path: "/dev/login"
      })

    task = learnings_task(project, "OPT-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7})

    preview = %Preview{task_id: task.id, url: "https://pr-7.preview.example.com", status: :live, live_sha: "aaa111"}

    %{task: task, preview: preview}
  end

  # The page reads the tab's address afresh once it is told, so the App item shows where the tab landed.
  test "opens a live preview in the app's tab at its login path, and says so to the task's page", %{
    task: %{id: task_id} = task,
    preview: preview
  } do
    %Preview{id: id} = Repo.insert!(preview)
    Phoenix.PubSub.subscribe(Rail.PubSub, "previews:#{task_id}")

    expect(Tools, :open_app_tab, fn %Task{id: ^task_id}, "app", "https://pr-7.preview.example.com/dev/login", [] ->
      :ok
    end)

    assert :ok = Pipeline.open_preview_tab(task)
    assert_received {:preview_changed, %Preview{id: ^id, status: :live}}
  end

  test "behind Access, the tab is given the cookie Access set for the project's token", %{
    task: task,
    preview: preview
  } do
    {:ok, _project} =
      Projects.update_project(system_scope(), task.project, %{
        preview_access_client_id: "id.access",
        preview_access_client_secret: "secret"
      })

    Repo.insert!(preview)

    Req.Test.expect(Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "cf-access-client-id") == ["id.access"]

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "CF_Authorization=eyJ.jwt.sig; Path=/")
      |> Req.Test.json(%{"sha" => "aaa111"})
    end)

    expect(Tools, :open_app_tab, fn _task, "app", _url, [%{name: "CF_Authorization", value: "eyJ.jwt.sig"}] -> :ok end)

    assert :ok = Pipeline.open_preview_tab(Repo.reload!(task))
  end

  test "a preview never looked for, or not serving the head commit, has no tab to open", %{
    task: task,
    preview: preview
  } do
    reject(Tools, :open_app_tab, 4)

    assert {:error, :not_live} = Pipeline.open_preview_tab(task)

    for status <- [:deploying, :gone] do
      Repo.insert!(%{preview | status: status}, on_conflict: :replace_all, conflict_target: :task_id)
      assert {:error, :not_live} = Pipeline.open_preview_tab(task)
    end
  end

  test "says why Access or the browser turned it away, and says nothing changed", %{task: task, preview: preview} do
    {:ok, _project} =
      Projects.update_project(system_scope(), task.project, %{
        preview_access_client_id: "id.access",
        preview_access_client_secret: "secret"
      })

    Repo.insert!(preview)
    Phoenix.PubSub.subscribe(Rail.PubSub, "previews:#{task.id}")

    Req.Test.expect(
      Client,
      &(&1 |> Plug.Conn.put_resp_header("set-cookie", "CF_Authorization=jwt") |> Req.Test.json(%{}))
    )

    expect(Tools, :open_app_tab, fn _task, "app", _url, [_cookie] -> {:error, {:cookie_refused, "CF_Authorization"}} end)
    assert {:error, {:cookie_refused, "CF_Authorization"}} = Pipeline.open_preview_tab(Repo.reload!(task))

    # Its one expected call is spent, so a tab opened without the cookie would fail here.
    Req.Test.expect(Client, &Req.Test.json(&1, %{"sha" => "aaa111"}))
    assert {:error, :no_access_cookie} = Pipeline.open_preview_tab(Repo.reload!(task))

    refute_received {:preview_changed, _preview}
  end
end
