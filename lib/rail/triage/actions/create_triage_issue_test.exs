defmodule Rail.Triage.Actions.CreateTriageIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  setup context do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, external: context[:external] == true)
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

  test "creates the issue as the person edited it and posts their reply with its link as them, starting no task", %{
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

    Req.Test.expect(Rail.Slack, fn conn ->
      assert conn.request_path == "/api/chat.postMessage"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{user.slack_access_token}"]

      assert %{
               "thread_ts" => "1790000000.000100",
               "text" =>
                 "Thanks Priya, we fixed the stuck tasks. Filed as <https://linear.app/acme/issue/TRI-214|TRI-214>."
             } = conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000500.000100"})
    end)

    assert {:ok,
            %Item{
              created_issue_id: "iss_" <> _id = issue_id,
              issue_created_by_id: ^user_id,
              issue_title: "Approve leaves tasks at Design, with no Design role",
              reply_posted_by_id: ^user_id,
              reply_posted_at: %DateTime{},
              error: nil
            }} =
             Triage.create_triage_issue(scope, item, %{
               "issue_title" => "Approve leaves tasks at Design, with no Design role",
               "issue_description" => "Edited.",
               "issue_priority" => "urgent",
               "reply_text" => "Thanks Priya, we fixed the stuck tasks. Filed as {issue link}."
             })

    assert %Thread{status: :done} = Repo.get!(Thread, thread.id)
    refute Repo.exists?(from(t in Task, where: t.issue_id == ^issue_id))

    assert %Message{sent_by_user_id: ^user_id, author_name: "Michael", text: "Thanks Priya" <> _rest} =
             Repo.get_by!(Message, external_id: "1790000500.000100")

    assert {:error, :already_created} = Triage.create_triage_issue(scope, item, %{})
  end

  test "posts only the link line when no reply was proposed, and keeps no error", %{
    thread: thread,
    scope: scope,
    linear_issue: linear_issue
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => nil})]})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
    end)

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Filed as <https://linear.app/acme/issue/TRI-214|TRI-214>"} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000600.000100"})
    end)

    assert {:ok, %Item{reply_posted_at: nil, error: nil}} =
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
    {:ok, _note} = Triage.add_triage_note(scope, item, %{"text" => "Billing has no Design role."})

    assert {:error, :locked} = Triage.create_triage_issue(scope, item, %{})
  end

  test "an item someone else is accepting right now creates nothing", %{thread: thread, scope: scope, user: user} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})
    Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [issue_created_by_id: user.id])

    assert {:error, :already_created} = Triage.create_triage_issue(scope, item, %{})
  end

  test "posts only the link line when someone else is posting the reply", %{
    thread: thread,
    scope: scope,
    workspace: workspace,
    linear_issue: linear_issue
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})
    %{id: other_id} = slack_user(workspace.external_id, "Jordan Ellis")
    Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [reply_posted_by_id: other_id])

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
    end)

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Filed as <https://linear.app/acme/issue/TRI-214|TRI-214>"} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000650.000100"})
    end)

    assert {:ok, %Item{reply_posted_at: nil, reply_posted_by_id: ^other_id}} =
             Triage.create_triage_issue(scope, item, %{})
  end

  test "a Linear failure frees the item to try again", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    Req.Test.expect(Rail.Linear, &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{})))

    assert {:error, {:linear_api_error, 500, _body}} = Triage.create_triage_issue(scope, item, %{"issue_title" => "Mine"})

    assert %Item{created_issue_id: nil, issue_created_by_id: nil, issue_title: "Approve leaves tasks at Design"} =
             Repo.get!(Item, item.id)
  end

  describe "in an external channel" do
    @describetag :external

    test "accepting with no reply creates the issue, posts nothing and starts no task", %{
      thread: thread,
      scope: scope,
      linear_issue: linear_issue
    } do
      %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => nil})]})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
      end)

      assert {:ok, %Item{created_issue_id: "iss_" <> _id = issue_id, reply_posted_at: nil, error: nil}} =
               Triage.create_triage_issue(scope, item, %{})

      refute Repo.exists?(from(t in Task, where: t.issue_id == ^issue_id))
      assert [] = Repo.all(from(m in Message, where: m.thread_id == ^thread.id and not is_nil(m.sent_by_user_id)))
    end

    test "accepting with a reply posts it exactly as written, with no Filed as line", %{
      thread: thread,
      scope: scope,
      user: %{id: user_id},
      linear_issue: linear_issue
    } do
      %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
      end)

      Req.Test.expect(Rail.Slack, fn conn ->
        assert %{"text" => "Thanks Priya, we reproduced this. We'll update this thread when it ships."} =
                 conn |> Req.Test.raw_body() |> Jason.decode!()

        Req.Test.json(conn, %{"ok" => true, "ts" => "1790003000.000100"})
      end)

      assert {:ok,
              %Item{
                created_issue_id: "iss_" <> _id,
                reply_posted_by_id: ^user_id,
                reply_text: "Thanks Priya, we reproduced this. We'll update this thread when it ships.",
                error: nil
              }} =
               Triage.create_triage_issue(scope, item, %{
                 "reply_text" => "Thanks Priya, we reproduced this. We'll update this thread when it ships."
               })

      assert %Item{reply_text: "Thanks Priya, we reproduced this. We'll update this thread when it ships."} =
               Repo.get!(Item, item.id)
    end

    test "a reply that links the issue creates nothing until the placeholder is taken out", %{
      thread: thread,
      scope: scope,
      linear_issue: linear_issue
    } do
      %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

      assert {:error, :external_issue_link} = Triage.create_triage_issue(scope, item, %{})

      assert {:error, :external_issue_link} =
               Triage.create_triage_issue(scope, item, %{"reply_text" => "Follow it in {issue link}."})

      assert %Item{created_issue_id: nil, issue_created_by_id: nil, reply_posted_by_id: nil} = Repo.get!(Item, item.id)

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
      end)

      Req.Test.expect(Rail.Slack, fn conn ->
        assert %{"text" => "Thanks, a fix is underway."} = conn |> Req.Test.raw_body() |> Jason.decode!()
        Req.Test.json(conn, %{"ok" => true, "ts" => "1790003100.000100"})
      end)

      assert {:ok, %Item{created_issue_id: "iss_" <> _id, reply_posted_at: %DateTime{}}} =
               Triage.create_triage_issue(scope, item, %{"reply_text" => "Thanks, a fix is underway."})

      assert %Item{reply_text: "Thanks, a fix is underway."} = Repo.get!(Item, item.id)
    end

    test "accepting while someone else posts the reply creates the issue and posts nothing", %{
      thread: thread,
      scope: scope,
      workspace: workspace,
      linear_issue: linear_issue
    } do
      %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})
      %{id: other_id} = slack_user(workspace.external_id, "Jordan Ellis")
      Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [reply_posted_by_id: other_id])

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
      end)

      assert {:ok, %Item{created_issue_id: "iss_" <> _id, reply_posted_at: nil, reply_posted_by_id: ^other_id}} =
               Triage.create_triage_issue(scope, item, %{})
    end

    test "once the channel is unmarked, accepting posts the issue's link again", %{
      project: project,
      channel: channel,
      thread: thread,
      scope: scope,
      linear_issue: linear_issue
    } do
      %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => nil})]})

      {:ok, _project} =
        Projects.update_project(system_scope(), project, %{
          "slack_channels" => [
            %{
              "id" => channel.id,
              "external_id" => channel.external_id,
              "name" => channel.name,
              "slack_workspace_id" => channel.slack_workspace_id,
              "external" => "false"
            }
          ]
        })

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}})
      end)

      Req.Test.expect(Rail.Slack, fn conn ->
        assert %{"text" => "Filed as <https://linear.app/acme/issue/TRI-214|TRI-214>"} =
                 conn |> Req.Test.raw_body() |> Jason.decode!()

        Req.Test.json(conn, %{"ok" => true, "ts" => "1790003200.000100"})
      end)

      assert {:ok, %Item{created_issue_id: "iss_" <> _id}} = Triage.create_triage_issue(scope, item, %{})
    end
  end
end
