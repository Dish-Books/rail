defmodule Rail.Triage.Actions.CreateForwardedIssuesTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.LinkTrackerUrl
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.Item, as: SupportItem
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup do
    %{project: project} = triage_project()
    unique = System.unique_integer([:positive])

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app#{unique}"}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    Req.Test.expect(Rail.Intercom, fn conn ->
      Req.Test.json(conn, %{
        "id" => "#{unique}",
        "created_at" => 1_790_000_000,
        "updated_at" => 1_790_000_100,
        "state" => "open",
        "source" => %{"id" => "src1", "body" => "<p>Two bugs.</p>", "author" => %{"type" => "user", "name" => "Marta"}}
      })
    end)

    {:ok, synced} = Support.sync_intercom_conversation(workspace, "#{unique}")
    {:ok, conversation} = Support.get_support_conversation(system_scope(), synced.id)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "cfi_#{unique}",
        login: "cfi_#{unique}",
        name: "Sam",
        email: "cfi_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    scope = Scope.for_user(user)

    items = [
      %SupportItem{
        key: "sesame",
        kind: :bug,
        title: "Sesame is missing",
        verdict: :confirmed,
        issue_title: "The allergen sheet lists sesame",
        issue_priority: :urgent,
        issue_estimate: 2
      },
      %SupportItem{
        key: "pdf",
        kind: :bug,
        title: "PDF cut off",
        verdict: :not_reproduced,
        issue_title: "A recipe's PDF prints the whole method",
        issue_priority: :high
      }
    ]

    {:ok, thread} = Triage.create_forwarded_thread(scope, conversation, items)
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

    %{project: project, thread: thread, scope: scope, user: user}
  end

  test "creates every open item's issue once, as typed, linked to the Intercom conversation, and settles the thread", %{
    thread: %{id: thread_id, permalink: permalink} = thread,
    scope: scope,
    user: %{id: user_id}
  } do
    [%Item{id: sesame_id}, %Item{id: pdf_id}] =
      Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

    drafts = %{sesame_id => %{"issue_title" => "Tahini recipes list sesame", "issue_estimate" => "3"}}

    assert {:ok, %Thread{status: :done}} = Triage.create_forwarded_issues(scope, thread, drafts)
    assert_receive {:triage_changed, ^thread_id}

    assert %Item{
             created_issue_id: sesame_issue_id,
             issue_created_by_id: ^user_id,
             issue_title: "Tahini recipes list sesame"
           } =
             Repo.get!(Item, sesame_id)

    assert %Item{created_issue_id: pdf_issue_id, issue_title: "A recipe's PDF prints the whole method"} =
             Repo.get!(Item, pdf_id)

    assert %Issue{title: "Tahini recipes list sesame", estimate: 3, priority: :urgent} = Repo.get!(Issue, sesame_issue_id)
    assert %Issue{priority: :high} = Repo.get!(Issue, pdf_issue_id)

    for issue_id <- [sesame_issue_id, pdf_issue_id] do
      assert_enqueued(worker: LinkTrackerUrl, args: %{issue_id: issue_id, url: permalink, title: "Intercom conversation"})
    end

    # A second click, or another tab, creates nothing more.
    reject(&Issues.create_issue/3)
    assert {:ok, %Thread{status: :done}} = Triage.create_forwarded_issues(scope, thread, drafts)
  end

  test "an item whose issue fails is named, the others are still created, and the thread keeps waiting", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    expect(Issues, :create_issue, fn _scope, _project, _attrs -> {:error, :tracker_down} end)
    stub(Issues, :create_issue, &Mimic.call_original(Issues, :create_issue, [&1, &2, &3]))

    assert {:error, {:not_created, [1]}} = Triage.create_forwarded_issues(scope, thread, %{})

    assert [%Item{created_issue_id: nil, issue_created_by_id: nil}, %Item{created_issue_id: "iss_" <> _id}] =
             Repo.all(from i in Item, where: i.thread_id == ^thread_id, order_by: i.position)

    assert %Thread{status: :waiting} = Repo.get!(Thread, thread_id)
  end

  test "an item someone else is creating right now is not created twice", %{
    thread: %{id: thread_id} = thread,
    scope: scope
  } do
    unique = System.unique_integer([:positive])

    {:ok, %{id: other_id}} =
      Users.register_oauth_user(%{github_id: "cfo_#{unique}", login: "cfo_#{unique}", email: "cfo_#{unique}@example.com"})

    Repo.update_all(from(i in Item, where: i.thread_id == ^thread_id), set: [issue_created_by_id: other_id])
    reject(&Issues.create_issue/3)

    assert {:ok, %Thread{}} = Triage.create_forwarded_issues(scope, thread, %{})
  end

  test "a person who cannot see the project, or a Slack thread, is not found", %{thread: thread} do
    assert {:error, :not_found} = Triage.create_forwarded_issues(user_scope(), thread, %{})

    %{workspace: workspace, channel: channel} = connect_slack_channel(triage_project().project)
    {:ok, slack_thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))

    assert {:error, :not_found} = Triage.create_forwarded_issues(system_scope(), slack_thread, %{})
  end
end
