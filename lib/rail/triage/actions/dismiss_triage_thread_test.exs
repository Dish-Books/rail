defmodule Rail.Triage.Actions.DismissTriageThreadTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread

  test "a dismissed thread is Done without accepting anything" do
    # A pass checks the default branch out and reads the Triage prompt from it, both through Rail.Git.
    # The project has no clone, so these answer as git would for a default branch with no .rail/prompts.
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    thread = triage_with(thread, %{"items" => [triage_bug()]})
    %{id: user_id} = user = slack_user(workspace.external_id, "Jordan Ellis")

    assert %Thread{status: :waiting} = thread

    assert {:ok, %Thread{status: :done, dismissed_by_id: ^user_id, dismissed_at: %DateTime{}}} =
             Triage.dismiss_triage_thread(Scope.for_user(user), thread)

    assert {:ok, %Thread{items: [_item]} = dismissed} = Triage.get_triage_thread(Scope.for_system(), thread.id)
    assert "Dismissed by Jordan Ellis" = Thread.outcome_label(dismissed)
  end
end
