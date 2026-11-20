defmodule Rail.Support.Actions.BackfillIntercomWorkspaceTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Intercom
  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Workers.BackfillIntercomWorkspace
  alias Rail.Support.Workers.SyncIntercomConversation

  setup do
    %{workspace: %IntercomWorkspace{id: "iw_backfill", access_token: "tok"}}
  end

  test "queues an imported sync of each conversation on the page, then the next page", %{workspace: workspace} do
    Req.Test.expect(
      Intercom,
      &Req.Test.json(&1, %{
        "conversations" => [%{"id" => 1}, %{"id" => "2"}],
        "pages" => %{"next" => %{"starting_after" => "cur_2"}}
      })
    )

    assert :ok = Support.backfill_intercom_workspace(workspace, nil)

    assert [
             %Oban.Job{
               args: %{"workspace_id" => "iw_backfill", "external_id" => "2", "imported" => true, "draft" => false}
             },
             %Oban.Job{args: %{"external_id" => "1", "imported" => true}}
           ] = all_enqueued(worker: SyncIntercomConversation)

    assert_enqueued(
      worker: BackfillIntercomWorkspace,
      args: %{"workspace_id" => "iw_backfill", "starting_after" => "cur_2"}
    )
  end

  test "the last page queues no next page", %{workspace: workspace} do
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"conversations" => [], "pages" => %{"next" => nil}}))

    assert :ok = Support.backfill_intercom_workspace(workspace, "cur_9")
    refute_enqueued(worker: BackfillIntercomWorkspace)
  end

  test "a page Intercom refuses is an error, so the job retries", %{workspace: workspace} do
    Req.Test.expect(Intercom, &Plug.Conn.send_resp(&1, 429, "slow down"))

    assert {:error, {:intercom_error, 429, "slow down"}} = Support.backfill_intercom_workspace(workspace, nil)
  end
end
