defmodule Rail.Triage.Actions.PostTriageReplyTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  setup context do
    %{project: project} = triage_project()
    %{workspace: workspace, channel: channel} = connect_slack_channel(project, external: context[:external] == true)
    {:ok, thread} = Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
    user = slack_user(workspace.external_id)

    %{workspace: workspace, channel: channel, thread: thread, user: user, scope: Scope.for_user(user), project: project}
  end

  test "posts the reply as the person edited it, as them, and the thread records it as theirs", %{
    thread: thread,
    scope: scope,
    user: %{id: user_id} = user
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil})]})

    Req.Test.expect(Rail.Slack, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{user.slack_access_token}"]
      assert %{"text" => "Fixed in TRI-9, thanks for the report."} = conn |> Req.Test.raw_body() |> Jason.decode!()
      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000700.000100"})
    end)

    assert {:ok, %Item{reply_posted_by_id: ^user_id, reply_posted_at: %DateTime{}}} =
             Triage.post_triage_reply(scope, item, %{"reply_text" => "Fixed in TRI-9, thanks for the report."})

    assert %Message{sent_by_user_id: ^user_id, text: "Fixed in TRI-9, thanks for the report."} =
             Repo.get_by!(Message, external_id: "1790000700.000100")

    assert %Thread{status: :done} = Repo.get!(Thread, thread.id)
    assert {:error, :already_posted} = Triage.post_triage_reply(scope, item, %{})
  end

  test "Slack's echo of that post is not triaged", %{
    workspace: workspace,
    channel: channel,
    thread: thread,
    scope: scope,
    user: %{id: user_id} = user
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790000800.000100"}))
    {:ok, _item} = Triage.post_triage_reply(scope, item, %{})
    Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

    echo =
      slack_message_event(channel, %{
        "ts" => "1790000800.000100",
        "thread_ts" => thread.external_id,
        "user" => user.slack_user_id,
        "text" => "On it."
      })

    assert {:ok, %Thread{id: thread_id}} = Triage.handle_slack_event(workspace, echo)
    refute_received {:triage_scheduled, ^thread_id, _delay}
    assert %Message{sent_by_user_id: ^user_id} = Repo.get_by!(Message, external_id: "1790000800.000100")

    reject(&Tools.run_agent/3)
    assert :ok = Triage.triage_thread(thread)
  end

  test "a person linked to another workspace is refused", %{thread: thread} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})

    assert {:error, :slack_other_workspace} =
             Triage.post_triage_reply(Scope.for_user(slack_user("T_ELSEWHERE")), item, %{})

    assert {:error, :slack_not_linked} = Triage.post_triage_reply(Scope.for_user(%{id: "usr_none"}), item, %{})
  end

  test "a reply waiting on its issue's link cannot go out before the issue exists", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    assert {:error, :needs_issue_link} = Triage.post_triage_reply(scope, item, %{"reply_text" => "Mine, {issue link}"})
    assert %Item{reply_text: "Thanks Priya, we reproduced this. Filed as {issue link}."} = Repo.get!(Item, item.id)
  end

  test "an item being triaged again is locked", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil})]})
    {:ok, _note} = Triage.add_triage_note(scope, item, %{"text" => "Wrong project."})

    assert {:error, :locked} = Triage.post_triage_reply(scope, item, %{})
  end

  test "a reply waiting on its issue's link goes out with it once the issue exists", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug()]})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_9",
              "identifier" => "TRI-9",
              "title" => "T",
              "url" => "https://linear.app/acme/issue/TRI-9",
              "state" => %{"type" => "triage"}
            }
          }
        }
      })
    end)

    stub(Rail.Pipeline, :start_task, fn _issue, :plan -> {:ok, :started} end)
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "not_in_channel"}))
    {:ok, %Item{reply_posted_at: nil}} = Triage.create_triage_issue(scope, item, %{})

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Thanks Priya, we reproduced this. Filed as <https://linear.app/acme/issue/TRI-9|TRI-9>."} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790001000.000100"})
    end)

    assert {:ok, %Item{reply_posted_at: %DateTime{}}} = Triage.post_triage_reply(scope, item, %{})
  end

  test "an item that proposed no reply has nothing to post", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"reply" => nil})]})

    assert {:error, :no_reply} = Triage.post_triage_reply(scope, item, %{})
  end

  test "the next pass reads the post as the teammate's, made through Rail", %{
    workspace: workspace,
    channel: channel,
    thread: thread,
    scope: scope
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "ts" => "1790001100.000100"}))
    {:ok, _item} = Triage.post_triage_reply(scope, item, %{})

    {:ok, thread} =
      Triage.handle_slack_event(
        workspace,
        slack_message_event(channel, %{
          "ts" => "1790001200.000100",
          "thread_ts" => thread.external_id,
          "text" => "Thanks!"
        })
      )

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      read = thread |> Thread.scratch_path() |> Path.join("thread.md") |> File.read!()
      assert read =~ "Michael (teammate, posted through Rail)"
      thread |> Thread.scratch_path() |> Path.join("result.json") |> File.write!(Jason.encode!(%{"items" => []}))
      {:ok, ""}
    end)

    assert :ok = Triage.triage_thread(thread)
  end

  test "a reply someone else is posting right now is not posted twice", %{
    thread: thread,
    scope: scope,
    workspace: workspace
  } do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})
    other = slack_user(workspace.external_id, "Jordan Ellis")
    Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [reply_posted_by_id: other.id])

    assert {:error, :already_posted} = Triage.post_triage_reply(scope, item, %{})
  end

  test "a post Slack refuses frees the reply to try again", %{thread: thread, scope: scope} do
    %Thread{items: [item]} = triage_with(thread, %{"items" => [triage_bug(%{"issue" => nil, "reply" => "On it."})]})
    Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "not_in_channel"}))

    assert {:error, {:slack_error, "not_in_channel"}} = Triage.post_triage_reply(scope, item, %{})
    assert %Item{reply_posted_by_id: nil, reply_posted_at: nil} = Repo.get!(Item, item.id)
  end

  test "a reply on an item an existing issue covers links that issue", %{
    project: project,
    thread: thread,
    scope: scope
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_11",
              "identifier" => "TRI-11",
              "title" => "Sidebar",
              "url" => "https://linear.app/acme/issue/TRI-11",
              "state" => %{"type" => "started"}
            }
          }
        }
      })
    end)

    {:ok, _issue} = Rail.Issues.create_issue(system_scope(), project, %{title: "Sidebar"})

    tracked = triage_bug(%{"existing_issue" => "TRI-11", "reply" => "Already tracked in {issue link}."})
    %Thread{items: [item]} = triage_with(thread, %{"items" => [tracked]})

    Req.Test.expect(Rail.Slack, fn conn ->
      assert %{"text" => "Already tracked in <https://linear.app/acme/issue/TRI-11|TRI-11>."} =
               conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"ok" => true, "ts" => "1790002000.000100"})
    end)

    assert {:ok, %Item{reply_posted_at: %DateTime{}}} = Triage.post_triage_reply(scope, item, %{})
  end

  describe "in an external channel" do
    @describetag :external

    setup %{project: project, thread: thread} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{
                "id" => "lin_12",
                "identifier" => "TRI-12",
                "title" => "Sidebar",
                "url" => "https://linear.app/acme/issue/TRI-12",
                "state" => %{"type" => "started"}
              }
            }
          }
        })
      end)

      {:ok, _issue} = Rail.Issues.create_issue(system_scope(), project, %{title: "Sidebar"})
      tracked = triage_bug(%{"existing_issue" => "TRI-12", "reply" => "Already tracked in {issue link}."})
      %Thread{items: [item]} = triage_with(thread, %{"items" => [tracked]})

      %{item: item}
    end

    test "a reply that links the issue is refused even though the issue exists, until the placeholder is out", %{
      item: item,
      scope: scope
    } do
      assert {:error, :external_issue_link} = Triage.post_triage_reply(scope, item, %{})
      assert %Item{reply_posted_by_id: nil, reply_posted_at: nil} = Repo.get!(Item, item.id)

      Req.Test.expect(Rail.Slack, fn conn ->
        assert %{"text" => "This is already tracked, and we'll post here when it ships."} =
                 conn |> Req.Test.raw_body() |> Jason.decode!()

        Req.Test.json(conn, %{"ok" => true, "ts" => "1790003300.000100"})
      end)

      assert {:ok, %Item{reply_posted_at: %DateTime{}}} =
               Triage.post_triage_reply(scope, item, %{
                 "reply_text" => "This is already tracked, and we'll post here when it ships."
               })
    end

    test "once the channel is unmarked, the placeholder links the issue again", %{
      project: project,
      channel: channel,
      item: item,
      scope: scope
    } do
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

      Req.Test.expect(Rail.Slack, fn conn ->
        assert %{"text" => "Already tracked in <https://linear.app/acme/issue/TRI-12|TRI-12>."} =
                 conn |> Req.Test.raw_body() |> Jason.decode!()

        Req.Test.json(conn, %{"ok" => true, "ts" => "1790003400.000100"})
      end)

      assert {:ok, %Item{reply_posted_at: %DateTime{}}} = Triage.post_triage_reply(scope, item, %{})
    end
  end
end
