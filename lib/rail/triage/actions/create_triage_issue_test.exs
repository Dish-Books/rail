defmodule Rail.Triage.Actions.CreateTriageIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  setup do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    user = slack_user(workspace.external_id)

    %{project: project, workspace: workspace, channel: channel, thread: thread, user: user, scope: Scope.for_user(user)}
  end

  setup do
    linear_issue = %{
      "id" => "lin_tri_214",
      "identifier" => "TRI-214",
      "title" => "Approve leaves tasks at Design, with no Design role",
      "url" => "https://linear.app/acme/issue/TRI-214",
      "state" => %{"id" => "st_tri", "name" => "Triage", "type" => "triage"}
    }

    %{linear_issue: linear_issue}
  end

  test "creates the issue with the person's edits, starts product, and posts the reply with its link as them", %{
    thread: thread,
    scope: scope,
    user: %{id: user_id} = user,
    linear_issue: linear_issue
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    Req.Test.expect(Rail.Linear, fn conn ->
      assert %{"variables" => %{"input" => input}} = conn |> Req.Test.raw_body() |> Jason.decode!()

      assert %{
               "title" => "Approve leaves tasks at Design, with no Design role",
               "description" => "Edited.",
               "priority" => 1
             } =
               input

      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
    end)

    expect(Pipeline, :start_task, fn %Issue{identifier: "TRI-214"}, :product -> {:ok, :started} end)

    Req.Test.expect(Rail.Slack, fn conn ->
      assert conn.request_path == "/api/chat.postMessage"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{user.slack_access_token}"]

      assert %{
               "thread_ts" => "1790000000.000100",
               "text" => "Thanks Priya, we reproduced this. Filed as <https://linear.app/acme/issue/TRI-214|TRI-214>."
             } = conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000500.000100"})
    end)

    assert {:ok,
            %Item{
              created_issue_id: "iss_" <> _issue_id,
              issue_created_by_id: ^user_id,
              issue_title: "Approve leaves tasks at Design, with no Design role",
              issue_edited_by_id: ^user_id,
              reply_posted_by_id: ^user_id,
              reply_posted_at: %DateTime{},
              error: nil
            }} =
             Triage.create_triage_issue(scope, item, %{
               "issue_title" => "Approve leaves tasks at Design, with no Design role",
               "issue_description" => "Edited.",
               "issue_priority" => "urgent"
             })

    assert %Thread{status: :done} = Repo.get!(Thread, thread.id)

    assert %Message{sent_by_user_id: ^user_id, author_name: "Michael", text: "Thanks Priya" <> _rest} =
             Repo.get_by!(Message, external_id: "1790000500.000100")

    assert {:error, :already_created} = Triage.create_triage_issue(scope, item, %{})
    assert {:error, :locked} = Triage.update_triage_draft(scope, item, %{"issue_title" => "Too late"})
  end

  test "posts only the link line when no reply was proposed", %{thread: thread, scope: scope, linear_issue: linear_issue} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => nil})]})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
    end)

    expect(Pipeline, :start_task, fn _issue, :product -> {:error, :no_backend} end)

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Filed as <https://linear.app/acme/issue/TRI-214|TRI-214>"} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000600.000100"})
    end)

    assert {:ok, %Item{reply_posted_at: nil, error: "Created TRI-214, but product did not start: :no_backend"}} =
             Triage.create_triage_issue(scope, item, %{})
  end

  test "appends the link when the reply leaves no place for it", %{
    thread: thread,
    scope: scope,
    linear_issue: linear_issue
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => "Thanks, we see it."})]})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
    end)

    expect(Pipeline, :start_task, fn _issue, :product -> {:ok, :started} end)

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Thanks, we see it.\n\nFiled as <https://linear.app/acme/issue/TRI-214|TRI-214>"} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => false, "error" => "channel_not_found"})
    end)

    assert {:ok, %Item{created_issue_id: "iss_" <> _id, error: "Created TRI-214, but could not post in Slack." <> _why}} =
             Triage.create_triage_issue(scope, item, %{})
  end

  test "a person without Slack linked creates nothing", %{thread: thread} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})
    unlinked = Scope.for_user(%{id: "usr_unlinked"})

    assert {:error, :slack_not_linked} = Triage.create_triage_issue(unlinked, item, %{})
    assert %Item{created_issue_id: nil} = Repo.get!(Item, item.id)
  end

  test "a person linked to another Slack workspace creates nothing", %{thread: thread} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    assert {:error, :slack_other_workspace} =
             Triage.create_triage_issue(Scope.for_user(slack_user("T_ELSEWHERE")), item, %{})
  end

  test "an item an existing issue covers is already tracked", %{project: project, thread: thread, scope: scope} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_23", "identifier" => "TRI-23", "title" => "T", "state" => %{"type" => "unstarted"}}
          }
        }
      })
    end)

    {:ok, _issue} = Rail.Issues.create_issue(system_scope(), project, %{title: "T"})
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"existing_issue" => "TRI-23"})]})

    assert {:error, :already_tracked} = Triage.create_triage_issue(scope, item, %{})
  end

  test "an item being triaged again is locked", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})
    {:ok, _correction} = Triage.correct_triage_item(scope, item, %{"text" => "Billing has no Design role."})

    assert {:error, :locked} = Triage.create_triage_issue(scope, item, %{})
  end

  test "an item someone else is accepting right now creates nothing", %{thread: thread, scope: scope, user: user} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})
    Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [issue_created_by_id: user.id])

    assert {:error, :already_created} = Triage.create_triage_issue(scope, item, %{})
  end

  test "a Linear failure frees the item to try again", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    Req.Test.expect(Rail.Linear, &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{})))

    assert {:error, {:linear_api_error, 500, _body}} = Triage.create_triage_issue(scope, item, %{})
    assert %Item{created_issue_id: nil, issue_created_by_id: nil} = Repo.get!(Item, item.id)
  end
end
