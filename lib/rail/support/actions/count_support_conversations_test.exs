defmodule Rail.Support.Actions.CountSupportConversationsTest do
  use Rail.DataCase, async: true

  alias Rail.Intercom
  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation

  setup %{project: project} do
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app_#{System.unique_integer([:positive])}"}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    for name <- ["a", "b", "c", "d"] do
      Req.Test.expect(Intercom, &Req.Test.json(&1, %{"id" => name, "updated_at" => 1_790_000_000}))
      {:ok, _conversation} = Support.sync_intercom_conversation(workspace, name)
    end

    Repo.update_all(from(c in Conversation, where: c.external_id == "b"), set: [drafting_since: DateTime.utc_now()])
    Repo.update_all(from(c in Conversation, where: c.external_id in ["c", "d"]), set: [status: :done])
    :ok
  end

  test "counts each queue filter, across every project or the ones named", %{
    project: %{id: project_id},
    github_project: %{id: github_project_id}
  } do
    assert %{waiting: 1, drafting: 1, done: 2} = Support.count_support_conversations([])
    assert %{waiting: 1, drafting: 1, done: 2} = Support.count_support_conversations(project_id: project_id)
    assert %{waiting: 0, drafting: 0, done: 0} = Support.count_support_conversations(project_id: [github_project_id])
  end
end
