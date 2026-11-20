defmodule Rail.Support.Workers.BackfillIntercomWorkspaceTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Intercom
  alias Rail.Support
  alias Rail.Support.Workers.BackfillIntercomWorkspace
  alias Rail.Support.Workers.SyncIntercomConversation

  test "imports the page the job names", %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, %{id: workspace_id}} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    Req.Test.expect(Intercom, fn conn ->
      assert %{"starting_after" => "cur_1"} = Plug.Conn.fetch_query_params(conn).query_params
      Req.Test.json(conn, %{"conversations" => [%{"id" => "5"}]})
    end)

    assert :ok = perform_job(BackfillIntercomWorkspace, %{"workspace_id" => workspace_id, "starting_after" => "cur_1"})
    assert_enqueued(worker: SyncIntercomConversation, args: %{"external_id" => "5"})
  end

  test "a workspace that is gone has nothing to import" do
    assert :ok = perform_job(BackfillIntercomWorkspace, %{"workspace_id" => "iw_gone"})
  end
end
