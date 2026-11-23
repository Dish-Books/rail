defmodule Rail.Triage.Actions.UpdateTriageReplyTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Scope
  alias Rail.Triage
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
    # An item with no ticket drafted, so the reply is the only thing to send.
    thread = triage_with(thread, triage_result([triage_bug(%{"issue" => nil})], %{"reply" => "Thanks Priya."}))
    {:ok, user} = Users.update_user(system_scope(), slack_user(workspace.external_id), %{project_ids: [project.id]})

    %{thread: thread, scope: Scope.for_user(user)}
  end

  test "saves the reply as typed, and emptying the last thing to send finishes the thread", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
    assert %Thread{status: :waiting} = thread

    assert {:ok, %Thread{status: :waiting, reply_text: "Thanks, Priya.\n\nOn it."}} =
             Triage.update_triage_reply(scope, thread, %{"reply_text" => "Thanks, Priya.\r\n\r\nOn it."})

    assert_received {:triage_changed, ^thread_id}

    assert {:ok, %Thread{status: :done, reply_text: nil}} =
             Triage.update_triage_reply(scope, thread, %{"reply_text" => ""})

    assert {:ok, %Thread{status: :waiting}} = Triage.update_triage_reply(scope, thread, %{"reply_text" => "Back."})
  end

  test "the reply as it stands saves nothing, even where an edit would be refused", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :triaging])

    assert {:ok, %Thread{reply_text: "Thanks Priya."}} =
             Triage.update_triage_reply(scope, thread, %{"reply_text" => "Thanks Priya."})
  end

  test "is refused while the agent works, once posted or dismissed, and outside the person's projects", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    attrs = %{"reply_text" => "Changed"}
    assert {:error, :not_found} = Triage.update_triage_reply(user_scope(project_ids: ["prj_other"]), thread, attrs)

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [status: :triaging])
    assert {:error, :triaging} = Triage.update_triage_reply(scope, thread, attrs)

    Repo.update_all(from(t in Thread, where: t.id == ^thread_id),
      set: [status: :done, reply_posted_at: DateTime.utc_now()]
    )

    assert {:error, :already_sent} = Triage.update_triage_reply(scope, thread, attrs)

    {:ok, _dismissed} = Triage.dismiss_triage_thread(scope, thread)
    assert {:error, :dismissed} = Triage.update_triage_reply(scope, thread, attrs)
    assert %Thread{reply_text: "Thanks Priya."} = Repo.get!(Thread, thread_id)
  end
end
