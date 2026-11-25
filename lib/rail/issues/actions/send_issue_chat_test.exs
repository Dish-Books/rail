defmodule Rail.Issues.Actions.SendIssueChatTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.ChatMessage
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.RunIssueChat
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Up next lists waiting tasks"})
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ich_#{unique}",
        login: "ich_#{unique}",
        name: "Sam Reyes",
        email: "ich_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    %{issue: issue, user: user, scope: Scope.for_user(user)}
  end

  test "records the person's line, asks the agent and tells the issue's page", %{
    issue: %{id: issue_id} = issue,
    user: %{id: user_id},
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issue_chats")

    assert {:ok, %ChatMessage{author: :person, text: "Is this still needed?", user_id: ^user_id, issue_id: ^issue_id}} =
             Issues.send_issue_chat(scope, issue, %{"text" => "  Is this still needed?  "})

    assert %Issue{chat_requested_at: %DateTime{}} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: RunIssueChat, args: %{"issue_id" => issue_id})
    assert_received {:issue_chat_changed, ^issue_id}
  end

  test "the next line after a failed pass clears its error and asks again", %{
    issue: %{id: issue_id} = issue,
    scope: scope
  } do
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [chat_error: "It was still running"])

    assert {:ok, %ChatMessage{}} = Issues.send_issue_chat(scope, issue, %{"text" => "Try again."})

    assert %Issue{chat_error: nil, chat_requested_at: %DateTime{}} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: RunIssueChat, args: %{"issue_id" => issue_id})
  end

  for {name, text, error} <- [
        {"a blank line", "   ", "can't be blank"},
        {"a line over 4000 characters", String.duplicate("a", 4001), "should be at most 4000 character(s)"}
      ] do
    @text text
    @error error

    test "#{name} is refused and asks for nothing", %{issue: %{id: issue_id} = issue, scope: scope} do
      assert {:error, %Ecto.Changeset{} = changeset} = Issues.send_issue_chat(scope, issue, %{"text" => @text})

      assert %{text: [@error]} = errors_on(changeset)
      assert %Issue{chat_requested_at: nil} = Repo.get!(Issue, issue_id)
      refute_enqueued(worker: RunIssueChat)
    end
  end

  test "an issue the agent is still answering takes no second line", %{issue: issue, scope: scope} do
    assert {:ok, %ChatMessage{}} = Issues.send_issue_chat(scope, issue, %{"text" => "Is this still needed?"})

    assert {:error, :agent_running} = Issues.send_issue_chat(scope, issue, %{"text" => "And make it 2 points."})

    assert [%ChatMessage{text: "Is this still needed?"}] = Repo.all(ChatMessage)
  end

  test "an issue with a task takes no line", %{issue: %{id: issue_id} = issue, scope: scope} do
    unique = System.unique_integer([:positive])

    %Task{id: UXID.generate!(prefix: "tsk")}
    |> Task.changeset(
      %{
        issue_id: issue_id,
        stage: :plan,
        worktree_name: "chat-#{unique}",
        worktree_path: "/tmp/chat-#{unique}/worktree",
        scratch_path: "/tmp/chat-#{unique}/scratch"
      },
      issue.project_id
    )
    |> Repo.insert!()

    assert {:error, :task_started} = Issues.send_issue_chat(scope, issue, %{"text" => "Is this still needed?"})

    assert Repo.all(ChatMessage) == []
    assert %Issue{chat_requested_at: nil} = Repo.get!(Issue, issue_id)
    refute_enqueued(worker: RunIssueChat)
  end

  test "an issue deleted since the page read it is not found", %{issue: issue, scope: scope} do
    Repo.delete!(issue)

    assert {:error, :not_found} = Issues.send_issue_chat(scope, issue, %{"text" => "Is this still needed?"})
  end

  test "a person without the issue's project is refused", %{issue: issue, user: user} do
    {:ok, outsider} = Users.update_user(system_scope(), user, %{project_ids: []})

    assert {:error, :not_found} =
             Issues.send_issue_chat(Scope.for_user(outsider), issue, %{"text" => "Is this still needed?"})

    assert Repo.all(ChatMessage) == []
  end
end
