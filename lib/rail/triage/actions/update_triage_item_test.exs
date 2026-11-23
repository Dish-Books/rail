defmodule Rail.Triage.Actions.UpdateTriageItemTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup do
    # A pass checks the default branch out and reads the Triage prompt from it, both through Rail.Git.
    # The project has no clone, so these answer as git would for a default branch with no .rail/prompts.
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    %{project: project} = triage_project(tracker: :local)
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    %Thread{items: [item]} = thread = triage_with(thread, triage_result([triage_bug()], %{"reply" => nil}))
    {:ok, user} = Users.update_user(system_scope(), slack_user(workspace.external_id), %{project_ids: [project.id]})

    %{thread: thread, item: item, scope: Scope.for_user(user)}
  end

  test "saves a card's edits as typed, and they are there after a reload", %{
    thread: %{id: thread_id},
    item: %{id: item_id} = item,
    scope: scope
  } do
    attrs = %{
      "kind" => "feature_request",
      "issue_title" => "Approving moves the task on",
      "issue_description" => "Line one\r\nLine two",
      "issue_priority" => "low",
      "issue_estimate" => "5"
    }

    assert {:ok, %Item{id: ^item_id}} = Triage.update_triage_item(scope, item, attrs)

    assert {:ok, %Thread{items: [%Item{} = saved]}} = Triage.get_triage_thread(scope, thread_id)

    assert %Item{
             kind: :feature_request,
             verdict: :confirmed,
             issue_title: "Approving moves the task on",
             issue_description: "Line one\nLine two",
             issue_priority: :low,
             issue_estimate: 5
           } = saved

    assert nil == Item.fitting_verdict(saved)
  end

  test "Ignore takes the last ticket out, finishing the thread, and switching it off brings it back", %{
    thread: %{id: thread_id},
    item: item,
    scope: scope
  } do
    assert {:ok, %Item{ignored: true}} = Triage.update_triage_item(scope, item, %{"ignored" => true})
    assert %Thread{status: :done} = Repo.get!(Thread, thread_id)

    assert {:ok, %Item{ignored: false}} = Triage.update_triage_item(scope, item, %{"ignored" => false})
    assert %Thread{status: :waiting} = Repo.get!(Thread, thread_id)
  end

  test "an edit Rail cannot take is refused with its errors", %{item: item, scope: scope} do
    assert {:error, %Ecto.Changeset{} = changeset} = Triage.update_triage_item(scope, item, %{"issue_estimate" => "4"})
    assert %{issue_estimate: ["is invalid"]} = errors_on(changeset)
  end

  test "is refused while the agent works, on a dismissed thread, once closed, gone, or outside the person's projects",
       %{thread: %{id: thread_id} = thread, item: %{id: item_id} = item, scope: scope} do
    attrs = %{"issue_title" => "Changed"}
    assert {:error, :not_found} = Triage.update_triage_item(user_scope(project_ids: ["prj_other"]), item, attrs)

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :triaging])
    assert {:error, :triaging} = Triage.update_triage_item(scope, item, attrs)

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :waiting])
    Repo.update_all(from(i in Item, where: i.id == ^item_id), set: [sent_at: DateTime.utc_now()])
    assert {:error, :closed} = Triage.update_triage_item(scope, item, attrs)

    {:ok, _dismissed} = Triage.dismiss_triage_thread(scope, thread)
    assert {:error, :dismissed} = Triage.update_triage_item(scope, item, attrs)

    Repo.delete_all(from i in Item, where: i.id == ^item_id)
    assert {:error, :gone} = Triage.update_triage_item(scope, item, attrs)
  end

  test "the card as it stands saves nothing", %{item: item, scope: scope} do
    assert {:ok, %Item{issue_title: "Approve leaves tasks at Design"}} =
             Triage.update_triage_item(scope, item, %{"issue_title" => "Approve leaves tasks at Design"})
  end
end
