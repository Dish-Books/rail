defmodule Rail.Support.Workers.NotifySupportMessageTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Intercom
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Support
  alias Rail.Support.Workers.NotifySupportMessage
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup {Req.Test, :verify_on_exit!}

  setup %{project: project} do
    unique = System.unique_integer([:positive])
    team_id = "T#{unique}"

    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
    {:ok, _workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-bot"})

    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app_#{unique}"}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok_ws",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    payload = %{
      "id" => "c#{unique}",
      "created_at" => 1_790_000_000,
      "updated_at" => 1_790_000_500,
      "state" => "open",
      "source" => %{
        "id" => "src1",
        "author" => %{"type" => "user", "name" => "Lena Hoffmann"},
        "body" => "<p>Bank feed stopped syncing after reconnecting Chase</p>"
      },
      "conversation_parts" => %{
        "conversation_parts" => [
          %{
            "id" => "p1",
            "part_type" => "comment",
            "created_at" => 1_790_000_100,
            "author" => %{"type" => "admin", "name" => "Dana"},
            "body" => "<p>Looking now.</p>"
          },
          %{
            "id" => "p2",
            "part_type" => "comment",
            "created_at" => 1_790_000_200,
            "author" => %{"type" => "user", "name" => "Lena Hoffmann"},
            "body" => "<p>Still   broken: total &lt; $5 &amp; more.</p><p>Second line</p>"
          }
        ]
      }
    }

    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))
    {:ok, conversation} = Support.sync_intercom_conversation(workspace, payload["id"])

    # Someone who would be told: a dev on the project with Slack linked and support messages on.
    subscriber = fn attrs ->
      id = System.unique_integer([:positive])

      {:ok, user} =
        Users.register_oauth_user(%{github_id: "nsm_#{id}", login: "nsm_#{id}", email: "nsm_#{id}@example.com"})

      {:ok, user} =
        Users.update_user(
          system_scope(),
          user,
          Map.merge(
            %{project_ids: [project.id], slack_user_id: "U#{id}", slack_team_id: team_id, slack_access_token: "xoxp"},
            Map.delete(attrs, :slack_support_notifications)
          )
        )

      {:ok, user} =
        user
        |> User.slack_notifications_changeset(%{
          slack_support_notifications: Map.get(attrs, :slack_support_notifications, true)
        })
        |> Repo.update()

      user
    end

    test_pid = self()

    posted = fn ->
      Req.Test.expect(Slack, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert "/api/chat.postMessage" = conn.request_path
        assert ["Bearer xoxb-bot"] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:posted, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000100"})
      end)
    end

    %{
      workspace: workspace,
      payload: payload,
      conversation: conversation,
      subscriber: subscriber,
      posted: posted,
      team_id: team_id
    }
  end

  describe "the job for a customer message" do
    test "queues one job for each teammate to tell, and none for anyone else", %{
      conversation: %{id: conversation_id},
      subscriber: subscriber
    } do
      %User{id: told_id} = subscriber.(%{})
      %User{id: support_id} = subscriber.(%{role: :support})
      # An admin sees every project, so needs none granted.
      %User{id: admin_id} = admin = subscriber.(%{admin: true, project_ids: []})
      _tester = subscriber.(%{role: :tester})
      _other_project = subscriber.(%{project_ids: ["prj_elsewhere"]})
      _no_projects = subscriber.(%{project_ids: []})
      _tasks_only = subscriber.(%{slack_support_notifications: false})
      removed = subscriber.(%{})
      {:ok, _removed} = Users.remove_user(Scope.for_user(admin), removed.id)

      assert :ok = perform_job(NotifySupportMessage, %{conversation_id: conversation_id, external_id: "p2"})

      assert Enum.sort([support_id, admin_id, told_id]) ==
               [worker: NotifySupportMessage]
               |> all_enqueued()
               |> Enum.map(fn %Oban.Job{args: %{"conversation_id" => ^conversation_id, "external_id" => "p2"} = args} ->
                 args["user_id"]
               end)
               |> Enum.sort()
    end

    test "for a conversation that is gone queues nothing", %{subscriber: subscriber} do
      _told = subscriber.(%{})

      assert :ok = perform_job(NotifySupportMessage, %{conversation_id: "scv_gone", external_id: "p2"})
      refute_enqueued(worker: NotifySupportMessage)
    end
  end

  describe "the job for one teammate" do
    test "sends one direct message linking to the conversation in Support, with the customer's words", %{
      conversation: %{id: conversation_id},
      subscriber: subscriber,
      posted: posted
    } do
      %User{id: user_id, slack_user_id: slack_user_id} = subscriber.(%{})

      posted.()

      assert :ok =
               perform_job(NotifySupportMessage, %{conversation_id: conversation_id, external_id: "p2", user_id: user_id})

      expected =
        "<#{RailWeb.Endpoint.url()}/support/#{conversation_id}|Bank feed stopped syncing after reconnecting Chase>\n" <>
          ">*Lena Hoffmann*: Still broken: total &lt; $5 &amp; more. Second line"

      assert_received {:posted, %{"channel" => ^slack_user_id, "text" => ^expected}}
    end

    test "titles it as the conversation's subject, and stops a long message at 200 characters", %{
      workspace: workspace,
      payload: payload,
      subscriber: subscriber,
      posted: posted
    } do
      %User{id: user_id} = subscriber.(%{})
      long = String.duplicate("abcd\n", 60)

      titled =
        payload
        |> put_in(["source", "subject"], "<p>Refund &amp; <b>invoice</b></p>")
        |> put_in(["conversation_parts", "conversation_parts"], [
          %{
            "id" => "p3",
            "part_type" => "comment",
            "created_at" => 1_790_000_300,
            "author" => %{"type" => "user", "name" => "Lena <Hoffmann>"},
            "body" => long
          }
        ])

      Req.Test.expect(Intercom, &Req.Test.json(&1, titled))
      {:ok, %{id: conversation_id}} = Support.sync_intercom_conversation(workspace, payload["id"])

      posted.()

      assert :ok =
               perform_job(NotifySupportMessage, %{conversation_id: conversation_id, external_id: "p3", user_id: user_id})

      excerpt = "abcd" |> List.duplicate(60) |> Enum.join(" ") |> String.slice(0, 200)

      expected =
        "<#{RailWeb.Endpoint.url()}/support/#{conversation_id}|Refund &amp; invoice>\n" <>
          ">*Lena &lt;Hoffmann&gt;*: #{excerpt}…"

      assert_received {:posted, %{"text" => ^expected}}
    end

    test "says the customer sent an attachment when the message has no words", %{
      workspace: workspace,
      payload: payload,
      subscriber: subscriber,
      posted: posted
    } do
      %User{id: user_id} = subscriber.(%{})

      picture = %{
        "id" => "p4",
        "part_type" => "comment",
        "created_at" => 1_790_000_400,
        "author" => %{"type" => "user", "name" => "Lena Hoffmann"},
        "body" => "<img src=\"https://downloads.intercomcdn.com/i/shot.png\">"
      }

      Req.Test.expect(
        Intercom,
        &Req.Test.json(&1, put_in(payload, ["conversation_parts", "conversation_parts"], [picture]))
      )

      {:ok, %{id: conversation_id}} = Support.sync_intercom_conversation(workspace, payload["id"])

      posted.()

      assert :ok =
               perform_job(NotifySupportMessage, %{conversation_id: conversation_id, external_id: "p4", user_id: user_id})

      assert_received {:posted, %{"text" => text}}
      assert String.ends_with?(text, "\n>*Lena Hoffmann* sent an attachment.")
    end

    test "sends nothing once they turned support messages off, unlinked Slack, or were removed", %{
      conversation: %{id: conversation_id},
      subscriber: subscriber,
      project: project
    } do
      turned_off = subscriber.(%{})
      {:ok, _off} = Users.set_slack_notifications(Scope.for_user(turned_off), :support, false)

      unlinked = subscriber.(%{})
      {:ok, _unlinked} = Users.unlink_slack(Scope.for_user(unlinked))

      removed = subscriber.(%{})
      {:ok, admin} = Users.update_user(system_scope(), subscriber.(%{}), %{admin: true, project_ids: [project.id]})
      {:ok, _removed} = Users.remove_user(Scope.for_user(admin), removed.id)

      # No Slack expectation is set, so any message would fail the test.
      for %User{id: user_id} <- [turned_off, unlinked, removed] do
        assert :ok =
                 perform_job(NotifySupportMessage, %{
                   conversation_id: conversation_id,
                   external_id: "p2",
                   user_id: user_id
                 })
      end
    end

    test "sends nothing once their role or projects no longer reach the conversation", %{
      conversation: %{id: conversation_id},
      subscriber: subscriber
    } do
      tester = subscriber.(%{})
      {:ok, _tester} = Users.update_user(system_scope(), tester, %{role: :tester})

      moved = subscriber.(%{})
      {:ok, _moved} = Users.update_user(system_scope(), moved, %{project_ids: ["prj_elsewhere"]})

      for %User{id: user_id} <- [tester, moved] do
        assert :ok =
                 perform_job(NotifySupportMessage, %{
                   conversation_id: conversation_id,
                   external_id: "p2",
                   user_id: user_id
                 })
      end
    end

    test "sends nothing for a teammate's message, a message or conversation that is gone, or a team Rail lost", %{
      conversation: %{id: conversation_id},
      subscriber: subscriber
    } do
      %User{id: user_id} = subscriber.(%{})
      %User{id: elsewhere_id} = subscriber.(%{slack_team_id: "T_ELSEWHERE"})

      for args <- [
            %{conversation_id: conversation_id, external_id: "p1", user_id: user_id},
            %{conversation_id: conversation_id, external_id: "p_gone", user_id: user_id},
            %{conversation_id: "scv_gone", external_id: "p2", user_id: user_id},
            %{conversation_id: conversation_id, external_id: "p2", user_id: "usr_gone"},
            %{conversation_id: conversation_id, external_id: "p2", user_id: elsewhere_id}
          ] do
        assert :ok = perform_job(NotifySupportMessage, args)
      end
    end

    test "a message Slack refuses fails this teammate's job alone, so Oban retries only theirs", %{
      conversation: %{id: conversation_id},
      subscriber: subscriber
    } do
      %User{id: user_id} = subscriber.(%{})
      Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "channel_not_found"}))

      assert_raise MatchError, fn ->
        perform_job(NotifySupportMessage, %{conversation_id: conversation_id, external_id: "p2", user_id: user_id})
      end
    end
  end
end
