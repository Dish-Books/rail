defmodule Rail.Issues.Actions.RunIssueChatTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.ChatMessage
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Mcp
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Users

  setup do
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    %{project: project, role: role} = triage_project()

    {:ok, issue} =
      Issues.create_issue(system_scope(), project, %{
        title: "Up next should show tasks waiting on other people too",
        description: "Up next only shows my own stuff.",
        priority: :medium,
        estimate: 3
      })

    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "irc_#{unique}",
        login: "irc_#{unique}",
        name: "Sam Reyes",
        email: "irc_#{unique}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    scope = Scope.for_user(user)
    {:ok, _line} = Issues.send_issue_chat(scope, issue, %{"text" => "Rewrite it to cover only what's left."})
    dir = Path.join([Rail.scratch_root(), project.id, "issue-chat", issue.id])

    %{project: project, role: role, issue: issue, scope: scope, dir: dir, result_path: Path.join(dir, "result.json")}
  end

  test "a pass rewrites the fields it changed, notes each one, answers and tells open pages", %{
    issue: %{id: issue_id} = issue,
    result_path: result_path
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "issue_chats")

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(
        result_path,
        Jason.encode!(%{
          "message" => "Rewrote it around tasks waiting on a teammate's question.",
          "ticket" => %{
            "title" => "Overview's Up next lists tasks waiting on a teammate's question",
            "description" => "A task waiting on a teammate's answer shows nowhere.",
            "priority" => "high",
            "estimate" => 2
          }
        })
      )

      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    assert %Issue{
             title: "Overview's Up next lists tasks waiting on a teammate's question",
             description: "A task waiting on a teammate's answer shows nowhere.",
             priority: :high,
             estimate: 2,
             chat_requested_at: nil,
             chat_started_at: nil,
             chat_token_hash: nil,
             chat_error: nil,
             chat_messages: [
               %ChatMessage{author: :person},
               %ChatMessage{
                 author: :agent,
                 user_id: nil,
                 text: "Rewrote it around tasks waiting on a teammate's question.",
                 changes: "Edited the title · Edited the description · Changed the priority · Changed the estimate"
               }
             ]
           } = Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)

    assert_received {:issue_changed, ^issue_id}
    assert_received {:issue_chat_changed, ^issue_id}
  end

  test "an answer that changes nothing leaves the ticket, notes nothing and tells no issue page", %{
    issue: %{id: issue_id} = issue,
    result_path: result_path
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(
        result_path,
        Jason.encode!(%{
          "message" => "It still applies. RAIL-203 covers only the first half.",
          "ticket" => %{"title" => issue.title, "priority" => "medium", "estimate" => 3}
        })
      )

      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    assert %Issue{title: "Up next should show tasks waiting on other people too", chat_messages: [_asked, answer]} =
             Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)

    assert %ChatMessage{text: "It still applies. RAIL-203 covers only the first half.", changes: nil} = answer
    refute_received {:issue_changed, ^issue_id}
  end

  test "a null ticket is an answer with no edits", %{issue: %{id: issue_id} = issue, result_path: result_path} do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"message" => "Still needed.", "ticket" => nil}))
      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    assert %Issue{chat_error: nil, chat_messages: [_asked, %ChatMessage{text: "Still needed.", changes: nil}]} =
             Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)
  end

  test "a description edited by hand while the agent worked keeps its text, and the title it changed is still written",
       %{issue: %{id: issue_id} = issue, scope: scope, result_path: result_path} do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      {:ok, _edited} = Issues.edit_issue(scope, issue, %{"description" => "RAIL-208 sat a day on Priya's question."})

      File.write!(
        result_path,
        Jason.encode!(%{
          "message" => "Retitled it.",
          "ticket" => %{
            "title" => "Overview's Up next lists tasks waiting on a teammate's question",
            "description" => "The agent's rewrite.",
            "estimate" => 2
          }
        })
      )

      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    assert %Issue{
             title: "Overview's Up next lists tasks waiting on a teammate's question",
             description: "RAIL-208 sat a day on Priya's question.",
             estimate: 2,
             chat_messages: [
               _asked,
               %ChatMessage{
                 changes: "Edited the title · Kept the description, edited while the agent worked · Changed the estimate"
               }
             ]
           } = Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)
  end

  test "a value the page could not set is left with a note, and the rest of the answer is kept", %{
    issue: %{id: issue_id} = issue,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(
        result_path,
        Jason.encode!(%{
          "message" => "Sharpened it.",
          "ticket" => %{
            "title" => "  ",
            "description" => "Sharper.",
            "priority" => "critical",
            "estimate" => 4
          }
        })
      )

      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    assert %Issue{
             title: "Up next should show tasks waiting on other people too",
             description: "Sharper.",
             priority: :medium,
             estimate: 3,
             chat_error: nil,
             chat_messages: [
               _asked,
               %ChatMessage{
                 text: "Sharpened it.",
                 changes:
                   ~s(Left the title: "  " is not a value Rail takes · Edited the description · Left the priority: "critical" is not a value Rail takes · Left the estimate: 4 is not a value Rail takes)
               }
             ]
           } = Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)
  end

  test "an estimate cleared to null and a description cleared to null are written", %{
    issue: %{id: issue_id} = issue,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(
        result_path,
        Jason.encode!(%{"message" => "Cleared.", "ticket" => %{"description" => nil, "estimate" => nil}})
      )

      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    assert %Issue{
             description: nil,
             estimate: nil,
             chat_messages: [_asked, %ChatMessage{changes: "Edited the description · Changed the estimate"}]
           } = Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)
  end

  test "a task started while the agent worked keeps the whole ticket as it was, and the answer is saved", %{
    issue: %{id: issue_id} = issue,
    result_path: result_path
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
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

      File.write!(
        result_path,
        Jason.encode!(%{"message" => "Rewrote it.", "ticket" => %{"title" => "Rewritten", "estimate" => 2}})
      )

      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    assert %Issue{
             title: "Up next should show tasks waiting on other people too",
             estimate: 3,
             chat_requested_at: nil,
             chat_messages: [
               _asked,
               %ChatMessage{text: "Rewrote it.", changes: "Left the ticket as it was: a task had started"}
             ]
           } = Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)
  end

  test "the agent reads the ticket, its comments and the chat, with who wrote each line", %{
    issue: issue,
    dir: dir,
    result_path: result_path
  } do
    %Comment{}
    |> Comment.changeset(%{issue_id: issue.id, body: "RAIL-208 sat for a day.", author_name: "Dana"})
    |> Repo.insert!()

    %Comment{} |> Comment.changeset(%{issue_id: issue.id, body: "Nameless comment."}) |> Repo.insert!()
    Repo.insert!(%ChatMessage{issue_id: issue.id, author: :agent, text: "Earlier answer."})
    Repo.insert!(%ChatMessage{issue_id: issue.id, author: :person, text: "From a deleted user."})

    {:ok, nameless} =
      Users.register_oauth_user(%{github_id: "nm_#{issue.id}", login: "nameless", email: "nm_#{issue.id}@example.com"})

    Repo.insert!(%ChatMessage{issue_id: issue.id, author: :person, user_id: nameless.id, text: "And be brief."})

    expect(Tools, :run_agent, fn _role, argv, _opts ->
      assert Enum.any?(argv, &(&1 =~ Path.join(dir, "chat.md")))
      File.write!(result_path, Jason.encode!(%{"message" => "Done."}))
      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)

    ticket = File.read!(Path.join(dir, "issue.md"))
    assert ticket =~ "# #{issue.identifier} Up next should show tasks waiting on other people too"
    assert ticket =~ "Status: Todo · Priority: Medium · Estimate: 3"
    assert ticket =~ "Up next only shows my own stuff."
    assert ticket =~ "### Dana · "
    assert ticket =~ "RAIL-208 sat for a day."
    assert ticket =~ "### A teammate · "

    chat = File.read!(Path.join(dir, "chat.md"))
    assert chat =~ "### Sam Reyes\n\nRewrite it to cover only what's left."
    assert chat =~ "### You\n\nEarlier answer."
    assert chat =~ "### A teammate\n\nFrom a deleted user."
    assert chat =~ "### nameless\n\nAnd be brief."
  end

  test "an issue with no description or comments says so", %{
    project: project,
    scope: scope,
    dir: dir
  } do
    {:ok, bare} = Issues.create_issue(system_scope(), project, %{title: "Bare"})
    {:ok, _line} = Issues.send_issue_chat(scope, bare, %{"text" => "Still needed?"})
    bare_dir = Path.join(Path.dirname(dir), bare.id)

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(Path.join(bare_dir, "result.json"), Jason.encode!(%{"message" => "Yes."}))
      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(bare)

    ticket = File.read!(Path.join(bare_dir, "issue.md"))
    assert ticket =~ "No description."
    assert ticket =~ "No comments."
  end

  test "a pass with the project's rules gives them to the agent", %{
    role: %{id: role_id},
    issue: %{id: issue_id} = issue,
    result_path: result_path
  } do
    expect(Learnings, :retrieve_learnings, fn %{id: ^role_id}, [_text] ->
      [%Learning{kind: :convention, rule: "Up next is per person."}]
    end)

    expect(Tools, :run_agent, fn _role, argv, _opts ->
      assert Enum.any?(argv, &(&1 =~ "Up next is per person."))
      File.write!(result_path, Jason.encode!(%{"message" => "Done."}))
      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)
    assert %Issue{chat_error: nil} = Repo.get!(Issue, issue_id)
  end

  test "a job for an issue nobody asked about runs nothing", %{issue: %{id: issue_id} = issue} do
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [chat_requested_at: nil])
    reject(Tools, :run_agent, 3)

    assert :ok = Issues.run_issue_chat(issue)
    assert %Issue{chat_started_at: nil, chat_token_hash: nil} = Repo.get!(Issue, issue_id)
  end

  test "a lock left by a pass that died long ago is taken over", %{
    issue: %{id: issue_id} = issue,
    result_path: result_path
  } do
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id),
      set: [chat_started_at: DateTime.shift(DateTime.utc_now(), minute: -46)]
    )

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(result_path, Jason.encode!(%{"message" => "Done."}))
      {:ok, ""}
    end)

    assert :ok = Issues.run_issue_chat(issue)
  end

  describe "a pass that fails leaves the ticket as it was, clears Running and says why" do
    for {name, body} <- [
          {"a result that is not JSON", "not json"},
          {"a result without a message", ~s({"ticket": {"title": "Rewritten"}})},
          {"a result that is not UTF-8", <<0xFF, 0xFE, 0x00>>}
        ] do
      @body body

      test "on #{name}", %{issue: %{id: issue_id} = issue, result_path: result_path} do
        expect(Tools, :run_agent, fn _role, _argv, _opts ->
          File.write!(result_path, @body)
          {:ok, ""}
        end)

        assert :ok = Issues.run_issue_chat(issue)

        assert %Issue{
                 title: "Up next should show tasks waiting on other people too",
                 chat_requested_at: nil,
                 chat_error: "The agent finished without writing a result Rail could read.",
                 chat_messages: [%ChatMessage{author: :person}]
               } = Issue |> Repo.get!(issue_id) |> Repo.preload(:chat_messages)
      end
    end

    test "on no result at all", %{issue: %{id: issue_id} = issue} do
      expect(Tools, :run_agent, fn _role, _argv, _opts -> {:ok, ""} end)

      assert :ok = Issues.run_issue_chat(issue)

      assert %Issue{chat_error: "The agent finished without writing a result Rail could read."} =
               Repo.get!(Issue, issue_id)
    end

    for {name, reason, error} <- [
          {"an exit with the CLI's reason", {:exit, 1, ~s({"type":"result","result":"Out of credits"})},
           "The agent exited with code 1: Out of credits"},
          {"an exit with no reason", {:exit, 2, ""}, "The agent exited with code 2."},
          {"a timeout", :timeout, "It was still running after 30 minutes, so it was stopped."},
          {"dispatch switched off", :dispatch_disabled, "Dispatch is switched off, so the agent did not run."},
          {"a signed-out backend", :backend_signed_out,
           "The Triage role's backend is signed out. Sign it in under Settings → Backends."},
          {"no account offering the model", "No account offers the model.", "No account offers the model."},
          {"anything else", {:surprise, 1}, "The agent failed: {:surprise, 1}"}
        ] do
      @reason reason
      @error error

      test "on #{name}", %{issue: %{id: issue_id} = issue} do
        Phoenix.PubSub.subscribe(Rail.PubSub, "issue_chats")
        expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, @reason} end)

        assert :ok = Issues.run_issue_chat(issue)

        assert %Issue{
                 title: "Up next should show tasks waiting on other people too",
                 description: "Up next only shows my own stuff.",
                 chat_requested_at: nil,
                 chat_started_at: nil,
                 chat_error: @error
               } = Repo.get!(Issue, issue_id)

        assert_received {:issue_chat_changed, ^issue_id}
      end
    end

    test "on a project with no Triage role", %{role: role, issue: %{id: issue_id} = issue} do
      {:ok, _deleted} = Roles.delete_role(system_scope(), role)

      assert :ok = Issues.run_issue_chat(issue)

      assert %Issue{chat_requested_at: nil, chat_error: "This project has no Triage role, which the issue chat runs on."} =
               Repo.get!(Issue, issue_id)
    end

    test "on an MCP server that needs reconnecting", %{issue: %{id: issue_id} = issue} do
      expect(Mcp, :check_run_tools, fn _context -> {:error, {:mcp_reconnect, ["linear"]}} end)

      assert :ok = Issues.run_issue_chat(issue)

      assert %Issue{chat_requested_at: nil, chat_error: "linear needs reconnecting" <> _rest} = Repo.get!(Issue, issue_id)
    end

    test "on a crash, which still raises, and Oban's retry runs no second pass", %{issue: %{id: issue_id} = issue} do
      expect(Tools, :run_agent, fn _role, _argv, _opts -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn -> Issues.run_issue_chat(issue) end

      assert %Issue{chat_requested_at: nil, chat_started_at: nil, chat_error: "The agent's pass crashed: boom"} =
               Repo.get!(Issue, issue_id)

      # The expect above allows one call, so a second pass would fail the test here.
      assert :ok = Issues.run_issue_chat(issue)
    end

    test "and the next line clears the error and asks again", %{issue: %{id: issue_id} = issue, scope: scope} do
      expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, :timeout} end)
      assert :ok = Issues.run_issue_chat(issue)

      assert {:ok, %ChatMessage{}} = Issues.send_issue_chat(scope, issue, %{"text" => "Try again."})
      assert %Issue{chat_error: nil, chat_requested_at: %DateTime{}} = Repo.get!(Issue, issue_id)
    end
  end

  describe "a pass that cannot run yet snoozes and stays Running" do
    test "when every account is used up", %{issue: %{id: issue_id} = issue} do
      resets_at = DateTime.shift(DateTime.utc_now(), minute: 10)
      expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, {:waiting_for_usage, resets_at}} end)

      assert {:snooze, seconds} = Issues.run_issue_chat(issue)
      assert seconds in 590..600

      assert %Issue{chat_requested_at: %DateTime{}, chat_started_at: nil, chat_token_hash: nil, chat_error: nil} =
               Repo.get!(Issue, issue_id)
    end

    test "when an account's usage resets in a moment", %{issue: issue} do
      expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, {:waiting_for_usage, DateTime.utc_now()}} end)

      assert {:snooze, 30} = Issues.run_issue_chat(issue)
    end

    test "when an MCP server did not answer", %{issue: %{id: issue_id} = issue} do
      expect(Mcp, :check_run_tools, fn _context -> {:error, {:mcp_unreachable, ["linear"]}} end)

      assert {:snooze, 30} = Issues.run_issue_chat(issue)
      assert %Issue{chat_requested_at: %DateTime{}, chat_error: nil} = Repo.get!(Issue, issue_id)
    end

    test "when another pass holds the issue", %{issue: %{id: issue_id} = issue} do
      Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [chat_started_at: DateTime.utc_now()])
      reject(Tools, :run_agent, 3)

      assert {:snooze, 30} = Issues.run_issue_chat(issue)
    end
  end
end
