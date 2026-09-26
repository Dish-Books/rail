defmodule Rail.Triage.Actions.UpdateTriageDraftTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => "Thanks."})]})
    %{id: user_id} = user = slack_user(workspace.external_id)

    %{item: item, user_id: user_id, scope: Scope.for_user(user)}
  end

  test "saves an edit as the person's and announces it", %{
    item: %{id: item_id, thread_id: thread_id} = item,
    user_id: user_id,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

    assert {:ok, %Item{id: ^item_id, issue_title: "Sharper title", issue_edited_by_id: ^user_id, reply_edited_by_id: nil}} =
             Triage.update_triage_draft(scope, item, %{"issue_title" => "Sharper title", "reply_text" => "Thanks."})

    assert_receive {:triage_changed, ^thread_id}
  end

  test "a draft is locked while its item is triaged again, and once it is accepted", %{item: item, scope: scope} do
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000900.000100"}))
    {:ok, _posted} = Triage.post_triage_reply(scope, item, %{})

    assert {:error, :locked} = Triage.update_triage_draft(scope, item, %{"reply_text" => "Changed my mind."})

    assert {:ok, %Item{issue_title: "Still open"}} =
             Triage.update_triage_draft(scope, item, %{"issue_title" => "Still open"})

    Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [created_issue_id: nil, retriaging: true])
    assert {:error, :locked} = Triage.update_triage_draft(scope, item, %{"issue_title" => "Nope"})
  end
end
