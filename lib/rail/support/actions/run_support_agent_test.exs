defmodule Rail.Support.Actions.RunSupportAgentTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Mcp
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Item
  alias Rail.Tools
  alias Rail.Users

  setup do
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    %{project: project, role: role} = triage_project()
    app_id = "app_#{System.unique_integer([:positive])}"

    payload = %{
      "id" => "123",
      "updated_at" => 1_790_000_100,
      "created_at" => 1_790_000_000,
      "state" => "open",
      "source" => %{
        "id" => "src1",
        "author" => %{"type" => "user", "name" => "Marta Kowalczyk", "email" => "marta@example.com"},
        "body" => "<p>The allergen sheet misses sesame.</p>",
        "attachments" => [
          %{
            "url" => "https://downloads.intercomcdn.com/files/report.pdf",
            "name" => "report.pdf",
            "content_type" => "application/pdf",
            "filesize" => 2048
          },
          %{"url" => "https://downloads.intercomcdn.com/files/gone.png", "name" => "gone.png"}
        ]
      },
      "conversation_parts" => %{
        "conversation_parts" => [
          %{
            "id" => "p1",
            "part_type" => "note",
            "created_at" => 1_790_000_050,
            "author" => %{"type" => "admin", "name" => "Dana"},
            "body" => "<p>Looks like a bug.</p>"
          },
          %{
            "id" => "p2",
            "part_type" => "comment",
            "created_at" => 1_790_000_060,
            "author" => %{"type" => "bot", "name" => "Fin"},
            "body" => "<p>Did that help?</p>"
          },
          %{
            "id" => "p3",
            "part_type" => "comment",
            "created_at" => 1_790_000_070,
            "author" => %{"type" => "admin", "name" => "Dana"},
            "body" => "<p>Looking into it.</p>"
          }
        ]
      }
    }

    Req.Test.stub(Rail.Intercom, fn
      %{request_path: "/me"} = conn -> Req.Test.json(conn, %{"app" => %{"id_code" => app_id}})
      %{request_path: "/conversations/123"} = conn -> Req.Test.json(conn, payload)
      %{request_path: "/files/report.pdf"} = conn -> Plug.Conn.send_resp(conn, 200, "%PDF-1.4 recipe")
      %{request_path: "/files/gone.png"} = conn -> Plug.Conn.send_resp(conn, 404, "gone")
    end)

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Acme Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    {:ok, conversation} = Support.sync_intercom_conversation(workspace, "123")
    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)

    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "sup_#{unique}",
        login: "sup_#{unique}",
        name: "Dana Whitfield",
        email: "sup_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    item = %{
      "key" => "sesame",
      "kind" => "bug",
      "title" => "The allergen sheet lists sesame for tahini",
      "verdict" => "confirmed",
      "summary" => "Tahini sits under Seeds.",
      "evidence" => [%{"file" => "lib/allergens.ex", "lines" => "42", "excerpt" => "tahini", "holds" => true}],
      "assumptions" => [%{"text" => "The recipe uses tahini."}],
      "existing_issue" => nil,
      "issue" => %{"title" => "Tahini shows sesame", "description" => "Seeds map.", "priority" => "high", "estimate" => 2}
    }

    %{
      project: project,
      role: role,
      workspace: workspace,
      conversation: conversation,
      scope: Scope.for_user(user),
      item: item,
      result_path: Path.join(Conversation.scratch_path(conversation), "result.json")
    }
  end

  test "a pass replaces the draft with its reply and items, titles the conversation and answers in the chat", %{
    conversation: %{id: conversation_id} = conversation,
    item: item,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(
        result_path,
        Jason.encode!(%{
          "title" => "Sesame is missing",
          "message" => "Sesame is a real bug.",
          "reply" => "Hi Marta, we passed this on to the dev team.",
          "items" => [item, "junk"]
        })
      )

      {:ok, ""}
    end)

    {:ok, _conversation} = Support.draft_support_reply(system_scope(), conversation)
    assert :ok = Support.run_support_agent(conversation)

    assert {:ok,
            %Conversation{
              title: "Sesame is missing",
              reply_text: "Hi Marta, we passed this on to the dev team.",
              drafting_since: nil,
              agent_started_at: nil,
              mcp_token_hash: nil,
              agent_error: nil,
              drafted_at: %DateTime{},
              items: [
                %Item{
                  key: "sesame",
                  position: 1,
                  kind: :bug,
                  verdict: :confirmed,
                  issue_title: "Tahini shows sesame",
                  issue_priority: :high,
                  issue_estimate: 2,
                  existing_issue_id: nil,
                  evidence: [%Item.Evidence{file: "lib/allergens.ex"}],
                  assumptions: [%Item.Assumption{text: "The recipe uses tahini.", corrected: false}]
                }
              ],
              chat_messages: [
                %ChatMessage{author: :agent, text: "Sesame is a real bug.", changes: "Added item 1"}
              ]
            }} = Support.get_support_conversation(system_scope(), conversation_id)
  end

  test "attachments are downloaded for the agent, and one Intercom will not hand over is noted", %{
    conversation: conversation
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:ok, ""} end)

    assert :ok = Support.run_support_agent(conversation)

    dir = Conversation.scratch_path(conversation)
    assert File.read!(Path.join([dir, "files", "src1-1-report.pdf"])) == "%PDF-1.4 recipe"
    assert File.read!(Path.join(dir, "conversation.md")) =~ "Rail could not download it: gone.png"
  end

  test "an item the agent names an existing ticket for is tracked and never forwarded", %{
    project: project,
    conversation: %{id: conversation_id} = conversation,
    item: item,
    result_path: result_path
  } do
    %{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        identifier: "#{project.key}-212",
        title: "A recipe scales from an event's cover count",
        state: :in_progress
      })
      |> Repo.insert!()

    expect(Issues, :get_project_issue, fn _project, "TRI-212" -> {:ok, issue} end)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      tracked = Map.merge(item, %{"key" => "scaling", "existing_issue" => "TRI-212", "issue" => nil})

      File.write!(
        result_path,
        Jason.encode!(%{"message" => "Scaling is TRI-212, In Progress.", "reply" => nil, "items" => [tracked]})
      )

      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)

    assert {:ok,
            %Conversation{
              reply_text: nil,
              items: [%Item{key: "scaling", existing_issue_id: ^issue_id}],
              chat_messages: [%ChatMessage{author: :agent, text: "Scaling is TRI-212, In Progress."}]
            } = loaded} = Support.get_support_conversation(system_scope(), conversation_id)

    assert Conversation.to_forward(loaded) == []
  end

  test "a forwarded item stays as it was, and an open item the result leaves out is deleted", %{
    conversation: %{id: conversation_id} = conversation,
    item: item,
    result_path: result_path
  } do
    other = Map.merge(item, %{"key" => "pdf", "title" => "The PDF prints the whole method"})

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => [item, other]}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)
    Repo.update_all(from(i in Item, where: i.key == "sesame"), set: [forwarded_at: DateTime.utc_now()])
    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      restated = Map.put(item, "title", "Rewritten after forwarding")
      File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => [restated]}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)

    assert {:ok,
            %Conversation{
              items: [
                %Item{key: "sesame", title: "The allergen sheet lists sesame for tahini", forwarded_at: %DateTime{}}
              ]
            }} = Support.get_support_conversation(system_scope(), conversation_id)

    assert %{"items" => [%{"key" => "sesame", "state" => "forwarded, closed to this pass"}, %{"state" => "to forward"}]} =
             conversation |> Conversation.scratch_path() |> Path.join("draft.json") |> File.read!() |> Jason.decode!()
  end

  test "draft.json names the ticket a tracked item is in", %{
    project: project,
    conversation: conversation,
    item: item,
    result_path: result_path
  } do
    %Issue{identifier: identifier} =
      issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        identifier: "#{project.key}-9",
        title: "Tracked",
        state: :todo
      })
      |> Repo.insert!()

    stub(Issues, :get_project_issue, fn _project, ^identifier -> {:ok, issue} end)

    expect(Tools, :run_agent, 2, fn _role, _argv, _opts ->
      tracked = Map.merge(item, %{"existing_issue" => identifier, "issue" => nil})
      File.write!(result_path, Jason.encode!(%{"message" => "Tracked.", "reply" => nil, "items" => [tracked]}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)
    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
    assert :ok = Support.run_support_agent(conversation)

    assert %{"items" => [%{"state" => "tracked in " <> ^identifier, "existing_issue" => ^identifier}]} =
             conversation |> Conversation.scratch_path() |> Path.join("draft.json") |> File.read!() |> Jason.decode!()
  end

  test "the agent's chat line says what each pass changed, and nothing when it changed nothing", %{
    conversation: %{id: conversation_id} = conversation,
    item: item,
    result_path: result_path
  } do
    second = Map.merge(item, %{"key" => "pdf", "title" => "The PDF prints the whole method"})

    results = [
      %{"message" => "First.", "reply" => "A", "items" => [item]},
      %{"message" => "Second.", "reply" => "B", "items" => [Map.put(item, "title", "Retitled"), second]},
      %{"message" => "Third.", "reply" => "B", "items" => [Map.put(item, "title", "Retitled"), second]}
    ]

    for result <- results do
      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        File.write!(result_path, Jason.encode!(result))
        {:ok, ""}
      end)

      {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)
      assert :ok = Support.run_support_agent(conversation)
    end

    assert {:ok,
            %Conversation{
              chat_messages: [
                %ChatMessage{text: "First.", changes: "Added item 1"},
                %ChatMessage{text: "Second.", changes: "Edited the reply · Edited item 1 · Added item 2"},
                %ChatMessage{text: "Third.", changes: nil}
              ]
            }} = Support.get_support_conversation(system_scope(), conversation_id)
  end

  test "the chat so far, from every author, is written for the next pass", %{
    conversation: conversation,
    scope: scope,
    result_path: result_path
  } do
    {:ok, nameless} =
      Users.register_oauth_user(%{github_id: "nm_#{conversation.id}", login: "nameless", email: "nm@example.com"})

    {:ok, _chat} = Support.send_support_chat(scope, conversation, %{"text" => "Drop the workaround."})

    {:ok, _chat} =
      Support.send_support_chat(Scope.for_user(%{nameless | admin: true}), conversation, %{"text" => "And be brief."})

    Repo.insert!(%ChatMessage{conversation_id: conversation.id, author: :person, text: "From a deleted user."})
    Repo.insert!(%ChatMessage{conversation_id: conversation.id, author: :agent, text: "Earlier answer."})

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => []}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)

    chat = conversation |> Conversation.scratch_path() |> Path.join("chat.md") |> File.read!()
    assert chat =~ "### Dana Whitfield\n\nDrop the workaround."
    assert chat =~ "### nameless\n\nAnd be brief."
    assert chat =~ "### Support\n\nFrom a deleted user."
    assert chat =~ "### You\n\nEarlier answer."
  end

  test "a pass with the project's rules saves its reply", %{
    role: %{id: role_id},
    conversation: %{id: conversation_id} = conversation,
    result_path: result_path
  } do
    expect(Learnings, :retrieve_learnings, fn %{id: ^role_id}, [_text] ->
      [%Learning{kind: :convention, rule: "Sesame is tracked under seeds."}]
    end)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => []}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)

    assert {:ok, %Conversation{reply_text: "Hi", agent_error: nil}} =
             Support.get_support_conversation(system_scope(), conversation_id)
  end

  test "a job with no draft asked for runs nothing", %{conversation: %{id: conversation_id} = conversation} do
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id), set: [drafting_since: nil])
    reject(Tools, :run_agent, 3)

    assert :ok = Support.run_support_agent(conversation)

    assert {:ok, %Conversation{agent_started_at: nil, mcp_token_hash: nil, chat_messages: []}} =
             Support.get_support_conversation(system_scope(), conversation_id)
  end

  test "drafted_at is when the pass began, so a customer message during it is newer", %{
    conversation: %{id: conversation_id} = conversation,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      send(self(), {:during, DateTime.utc_now()})
      File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => []}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)
    assert_received {:during, during}
    assert %Conversation{drafted_at: drafted_at} = Repo.get!(Conversation, conversation_id)
    assert DateTime.before?(drafted_at, during)
  end

  test "a pass after the reply posted keeps the posted reply and still changes the list", %{
    conversation: %{id: conversation_id} = conversation,
    item: item,
    result_path: result_path
  } do
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
      set: [reply_text: "Sent reply", reply_posted_at: DateTime.utc_now()]
    )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      assert %{"reply_posted" => true, "reply" => "Sent reply"} =
               conversation |> Conversation.scratch_path() |> Path.join("draft.json") |> File.read!() |> Jason.decode!()

      File.write!(result_path, Jason.encode!(%{"message" => "Added it.", "reply" => "A new reply", "items" => [item]}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)

    assert {:ok,
            %Conversation{
              reply_text: "Sent reply",
              items: [%Item{key: "sesame"}],
              chat_messages: [%ChatMessage{changes: "Added item 1"}]
            }} = Support.get_support_conversation(system_scope(), conversation_id)
  end

  test "a reply Send posts while the pass runs is kept, and an item it forwarded stays as it was forwarded", %{
    conversation: %{id: conversation_id} = conversation,
    item: item,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"message" => "Drafted.", "reply" => "Hi", "items" => [item]}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)
    {:ok, _drafting} = Support.draft_support_reply(system_scope(), conversation)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
        set: [reply_posted_at: DateTime.utc_now()]
      )

      Repo.update_all(from(i in Item, where: i.conversation_id == ^conversation_id),
        set: [forwarded_at: DateTime.utc_now()]
      )

      renamed = Map.put(item, "title", "Renamed")
      File.write!(result_path, Jason.encode!(%{"message" => "Renamed.", "reply" => "Rewritten", "items" => [renamed]}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)

    assert {:ok,
            %Conversation{
              reply_text: "Hi",
              items: [
                %Item{key: "sesame", title: "The allergen sheet lists sesame for tahini", forwarded_at: %DateTime{}}
              ]
            }} = Support.get_support_conversation(system_scope(), conversation_id)
  end

  describe "a pass that fails keeps the draft as it was, clears Drafting and says why" do
    setup %{conversation: conversation, item: item, result_path: result_path} do
      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        File.write!(result_path, Jason.encode!(%{"message" => "Drafted.", "reply" => "Kept reply", "items" => [item]}))
        {:ok, ""}
      end)

      :ok = Support.run_support_agent(conversation)
      {:ok, _conversation} = Support.draft_support_reply(system_scope(), conversation)
      :ok
    end

    for {name, body, error} <- [
          {"an unknown verdict",
           ~s({"message": "m", "reply": "New", "items": [{"key": "a", "kind": "bug", "title": "t", "verdict": "maybe", "issue": {"title": "x"}}]}),
           ~s(The agent listed an item Rail could not save: item "a": verdict is invalid.)},
          {"a verdict that does not fit the kind",
           ~s({"message": "m", "reply": "New", "items": [{"key": "a", "kind": "bug", "title": "t", "verdict": "built", "issue": {"title": "x"}}]}),
           ~s(The agent listed an item Rail could not save: item "a": verdict does not fit the kind.)},
          {"an item with neither a ticket nor an issue title",
           ~s({"message": "m", "reply": "New", "items": [{"key": "a", "kind": "bug", "title": "t", "verdict": "confirmed"}]}),
           ~s(The agent listed an item Rail could not save: item "a": issue title can't be blank.)},
          {"an item whose evidence Rail cannot read",
           ~s({"message": "m", "reply": "New", "items": [{"key": "a", "kind": "bug", "title": "t", "verdict": "confirmed", "evidence": [{"holds": "maybe"}], "issue": {"title": "x"}}]}),
           ~s(The agent listed an item Rail could not save: item "a": has evidence or assumptions Rail could not read.)},
          {"a result that is not JSON", "not json", "The agent finished without writing a result Rail could read."},
          {"a result without a reply", ~s({"message": "m", "items": []}),
           "The agent finished without writing a result Rail could read."}
        ] do
      @body body
      @error error

      test "on #{name}", %{conversation: %{id: conversation_id} = conversation, result_path: result_path} do
        expect(Tools, :run_agent, fn _role, _argv, _opts ->
          File.write!(result_path, @body)
          {:ok, ""}
        end)

        assert :ok = Support.run_support_agent(conversation)

        assert {:ok,
                %Conversation{
                  reply_text: "Kept reply",
                  drafting_since: nil,
                  agent_error: @error,
                  items: [%Item{key: "sesame", title: "The allergen sheet lists sesame for tahini"}]
                }} = Support.get_support_conversation(system_scope(), conversation_id)
      end
    end

    test "on no result at all", %{conversation: %{id: conversation_id} = conversation} do
      expect(Tools, :run_agent, fn _role, _argv, _opts -> {:ok, ""} end)

      assert :ok = Support.run_support_agent(conversation)

      assert {:ok,
              %Conversation{
                reply_text: "Kept reply",
                drafting_since: nil,
                agent_error: "The agent finished without writing a result Rail could read."
              }} = Support.get_support_conversation(system_scope(), conversation_id)
    end

    for {name, reason, error} <- [
          {"an exit with the CLI's reason", {:exit, 1, ~s({"type":"result","result":"Out of credits"})},
           "The agent exited with code 1: Out of credits"},
          {"an exit with no reason", {:exit, 2, ""}, "The agent exited with code 2."},
          {"a timeout", :timeout, "The agent was still running after 30 minutes, so it was stopped."},
          {"dispatch switched off", :dispatch_disabled, "Dispatch is switched off, so the agent did not run."},
          {"a signed-out backend", :backend_signed_out,
           "The Triage role's backend is signed out, so the agent did not run. Sign it in under Settings → Backends, then try again."},
          {"no account offering the model", "No account offers the model.", "No account offers the model."},
          {"anything else", {:surprise, 1}, "The agent failed: {:surprise, 1}"}
        ] do
      @reason reason
      @error error

      test "on #{name}", %{conversation: %{id: conversation_id} = conversation} do
        expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, @reason} end)

        assert :ok = Support.run_support_agent(conversation)

        assert {:ok, %Conversation{reply_text: "Kept reply", drafting_since: nil, agent_error: @error}} =
                 Support.get_support_conversation(system_scope(), conversation_id)
      end
    end

    test "on a project with no Triage role", %{role: role, conversation: %{id: conversation_id} = conversation} do
      {:ok, _deleted} = Roles.delete_role(system_scope(), role)

      assert :ok = Support.run_support_agent(conversation)

      assert {:ok,
              %Conversation{
                drafting_since: nil,
                agent_error: "This project has no Triage role, which the support agent runs on."
              }} = Support.get_support_conversation(system_scope(), conversation_id)
    end

    test "on an MCP server that needs reconnecting", %{conversation: %{id: conversation_id} = conversation} do
      expect(Mcp, :check_run_tools, fn _context -> {:error, {:mcp_reconnect, ["linear"]}} end)

      assert :ok = Support.run_support_agent(conversation)

      assert {:ok, %Conversation{drafting_since: nil, agent_error: "linear needs reconnecting" <> _rest}} =
               Support.get_support_conversation(system_scope(), conversation_id)
    end

    test "on a crash, which still raises, and Oban's retry runs no second pass", %{
      conversation: %{id: conversation_id} = conversation
    } do
      expect(Tools, :run_agent, fn _role, _argv, _opts -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn -> Support.run_support_agent(conversation) end

      assert {:ok,
              %Conversation{
                reply_text: "Kept reply",
                drafting_since: nil,
                agent_started_at: nil,
                agent_error: "The agent's pass crashed: boom"
              }} = Support.get_support_conversation(system_scope(), conversation_id)

      # The expect above allows one call, so a second pass would fail the test here.
      assert :ok = Support.run_support_agent(conversation)

      assert {:ok, %Conversation{reply_text: "Kept reply", agent_error: "The agent's pass crashed: boom"}} =
               Support.get_support_conversation(system_scope(), conversation_id)
    end

    test "and a chat line during it asks for no new pass", %{
      scope: scope,
      conversation: %{id: conversation_id} = conversation
    } do
      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        {:ok, _chat} = Support.send_support_chat(scope, conversation, %{"text" => "Shorter please."})
        {:error, :timeout}
      end)

      assert :ok = Support.run_support_agent(conversation)

      assert {:ok, %Conversation{drafting_since: nil, agent_error: "The agent was still running" <> _rest}} =
               Support.get_support_conversation(system_scope(), conversation_id)
    end
  end

  describe "a pass that cannot run yet snoozes and stays Drafting" do
    setup %{conversation: conversation} do
      {:ok, _conversation} = Support.draft_support_reply(system_scope(), conversation)
      :ok
    end

    test "when every account is used up", %{conversation: %{id: conversation_id} = conversation} do
      resets_at = DateTime.shift(DateTime.utc_now(), minute: 10)
      expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, {:waiting_for_usage, resets_at}} end)

      assert {:snooze, seconds} = Support.run_support_agent(conversation)
      assert seconds in 590..600

      assert {:ok,
              %Conversation{drafting_since: %DateTime{}, agent_started_at: nil, mcp_token_hash: nil, agent_error: nil}} =
               Support.get_support_conversation(system_scope(), conversation_id)
    end

    test "when an account's usage resets in a moment", %{conversation: conversation} do
      expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, {:waiting_for_usage, DateTime.utc_now()}} end)

      assert {:snooze, 30} = Support.run_support_agent(conversation)
    end

    test "when an MCP server did not answer", %{conversation: %{id: conversation_id} = conversation} do
      expect(Mcp, :check_run_tools, fn _context -> {:error, {:mcp_unreachable, ["linear"]}} end)

      assert {:snooze, 30} = Support.run_support_agent(conversation)

      assert {:ok, %Conversation{drafting_since: %DateTime{}, agent_error: nil}} =
               Support.get_support_conversation(system_scope(), conversation_id)
    end

    test "when another pass holds the conversation", %{conversation: %{id: conversation_id} = conversation} do
      Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
        set: [agent_started_at: DateTime.utc_now()]
      )

      reject(Tools, :run_agent, 3)

      assert {:snooze, 30} = Support.run_support_agent(conversation)
    end
  end

  test "a lock left by a pass that died long ago is taken over", %{
    conversation: %{id: conversation_id} = conversation,
    result_path: result_path
  } do
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
      set: [agent_started_at: DateTime.shift(DateTime.utc_now(), minute: -46)]
    )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => []}))
      {:ok, ""}
    end)

    assert :ok = Support.run_support_agent(conversation)
  end

  describe "what arrives during a pass gets a pass of its own" do
    test "a chat line", %{scope: scope, conversation: %{id: conversation_id} = conversation, result_path: result_path} do
      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        {:ok, _chat} = Support.send_support_chat(scope, conversation, %{"text" => "Shorter please."})
        File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => []}))
        {:ok, ""}
      end)

      assert :ok = Support.run_support_agent(conversation)

      # finish clears Drafting, so only the new request sets it again.
      assert {:ok, %Conversation{drafting_since: %DateTime{}, drafted_at: %DateTime{}}} =
               Support.get_support_conversation(system_scope(), conversation_id)
    end

    test "a customer message", %{
      workspace: workspace,
      conversation: %{id: conversation_id} = conversation,
      result_path: result_path
    } do
      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        Req.Test.stub(Rail.Intercom, fn
          %{request_path: "/conversations/123"} = conn ->
            Req.Test.json(conn, %{
              "id" => "123",
              "updated_at" => 1_790_000_200,
              "created_at" => 1_790_000_000,
              "state" => "open",
              "source" => %{"id" => "src1", "author" => %{"type" => "user", "name" => "Marta"}, "body" => "<p>Hi</p>"},
              "conversation_parts" => %{
                "conversation_parts" => [
                  %{
                    "id" => "p9",
                    "part_type" => "comment",
                    "created_at" => 1_790_000_190,
                    "author" => %{"type" => "user", "name" => "Marta"},
                    "body" => "<p>Also the menu card.</p>"
                  }
                ]
              }
            })
        end)

        {:ok, _conversation} = Support.sync_intercom_conversation(workspace, "123")
        File.write!(result_path, Jason.encode!(%{"message" => "Done.", "reply" => "Hi", "items" => []}))
        {:ok, ""}
      end)

      assert :ok = Support.run_support_agent(conversation)

      assert {:ok, %Conversation{drafting_since: %DateTime{}}} =
               Support.get_support_conversation(system_scope(), conversation_id)
    end
  end
end
