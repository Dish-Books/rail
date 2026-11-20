defmodule Rail.Support.Actions.RunSupportAgent do
  @moduledoc """
  Runs the support agent once on a conversation: it reads the conversation, the draft and the chat
  against the project's code and tickets, and writes one result file that replaces the draft.
  """

  import Ecto.Query
  import Rail.Support.Utils.RequestSupportDraft

  alias Rail.Git
  alias Rail.Intercom
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Item
  alias Rail.Support.Schemas.Message
  alias Rail.Tools

  @stale_after_minutes 45
  @timeout to_timeout(minute: 30)
  @compared [:title, :kind, :verdict, :issue_title, :issue_description, :issue_priority, :issue_estimate]

  @doc """
  Returns `:ok`, without a pass when no draft is asked for, or `{:snooze, seconds}` when another pass holds
  the conversation, an MCP server did not answer, or every account is used up. A failed pass keeps the draft.
  """
  def run_support_agent(%Conversation{id: id}) do
    {token, hash} = Mcp.issue_run_token()
    started_at = DateTime.utc_now()
    stale = DateTime.shift(started_at, minute: -@stale_after_minutes)

    # Only a conversation someone asked a draft for: a retried or rescued job whose pass already finished runs nothing.
    {claimed, _rows} =
      Repo.update_all(
        from(c in Conversation,
          where:
            c.id == ^id and not is_nil(c.drafting_since) and
              (is_nil(c.agent_started_at) or c.agent_started_at < ^stale)
        ),
        set: [agent_started_at: started_at, mcp_token_hash: hash]
      )

    cond do
      claimed == 1 -> run(Repo.get!(Conversation, id), token, started_at)
      Repo.exists?(from c in Conversation, where: c.id == ^id and not is_nil(c.drafting_since)) -> {:snooze, 30}
      true -> :ok
    end
  end

  defp run(%Conversation{} = conversation, token, started_at) do
    conversation = load(conversation)

    outcome =
      try do
        pass(conversation, token)
      rescue
        # A crash still reaches Sentry, but never leaves the conversation stuck in Drafting.
        exception ->
          finish(conversation, {:error, "The agent's pass crashed: #{Exception.message(exception)}"}, started_at)
          reraise exception, __STACKTRACE__
      after
        _removed = Git.remove_worktree(conversation.project.clone_path, Conversation.worktree_path(conversation))
      end

    finish(conversation, outcome, started_at)

    case outcome do
      {:error, {:waiting_for_usage, resets_at}} -> {:snooze, max(DateTime.diff(resets_at, DateTime.utc_now()), 30)}
      {:error, {:mcp_unreachable, _names}} -> {:snooze, 30}
      _ran_or_failed -> :ok
    end
  end

  defp pass(conversation, token) do
    with {:ok, role} <- role(conversation),
         :ok <- check_tools(conversation, role),
         :ok <- write_files(conversation),
         {:ok, worktree} <- Git.checkout_detached_worktree(conversation.project, Conversation.worktree_path(conversation)),
         {:ok, _output} <- agent(conversation, role, worktree, token),
         {:ok, result} <- read_result(conversation) do
      apply_result(conversation, result)
    end
  end

  defp load(conversation) do
    Repo.preload(conversation, [
      :intercom_workspace,
      project: :triage_user,
      messages: from(m in Message, order_by: [asc: m.posted_at, asc: m.id]),
      items: from(i in Item, order_by: [asc: i.position, asc: i.id], preload: :existing_issue),
      chat_messages: from(c in ChatMessage, order_by: [asc: c.inserted_at, asc: c.id], preload: :user)
    ])
  end

  defp role(%Conversation{project_id: project_id}) do
    case Roles.get_role(project_id: project_id, stage: :triage) do
      {:ok, role} -> {:ok, role}
      {:error, :role_not_found} -> {:error, "This project has no Triage role, which the support agent runs on."}
    end
  end

  defp check_tools(%Conversation{project: project}, role) do
    case Mcp.check_run_tools(%RunContext{role: role, user: project.triage_user}) do
      :ok ->
        :ok

      {:error, {:mcp_unreachable, _names}} = unreachable ->
        unreachable

      {:error, {:mcp_reconnect, names}} ->
        {:error,
         "#{Enum.join(names, ", ")} needs reconnecting for the project's triage user under Settings → Connected accounts."}
    end
  end

  defp write_files(%Conversation{} = conversation) do
    dir = Conversation.scratch_path(conversation)
    files_dir = Path.join(dir, "files")
    File.rm_rf!(files_dir)
    File.mkdir_p!(files_dir)
    File.rm(Path.join(dir, "result.json"))

    File.write!(Path.join(dir, "conversation.md"), conversation_file(conversation, files_dir))
    File.write!(Path.join(dir, "draft.json"), Jason.encode!(draft(conversation), pretty: true))
    File.write!(Path.join(dir, "chat.md"), chat_file(conversation))
    :ok
  end

  defp agent(%Conversation{} = conversation, role, worktree, token) do
    args =
      Tools.build_args(
        prompt: Pipeline.build_prompt(context_snippet: brief(conversation, role)),
        model: role.model,
        reasoning_effort: to_string(role.reasoning_effort || :high),
        system_prompt: role.system_prompt,
        work_dir: worktree
      )

    Tools.run_agent(role, args, env: %{"RAIL_MCP_TOKEN" => token}, cd: worktree, timeout: @timeout)
  end

  defp read_result(conversation) do
    with {:ok, body} <- File.read(Path.join(Conversation.scratch_path(conversation), "result.json")),
         {:ok, %{"reply" => reply, "message" => message, "items" => items} = result}
         when is_binary(message) and is_list(items) and (is_binary(reply) or is_nil(reply)) <- Jason.decode(body) do
      {:ok, result}
    else
      _unreadable -> {:error, "The agent finished without writing a result Rail could read."}
    end
  end

  # Forwarded items are closed: a pass never changes them, and an open one it leaves out is gone.
  defp apply_result(%Conversation{} = conversation, %{"items" => items} = result) do
    issues = existing_issues(conversation.project, items)

    Repo.transaction(fn ->
      # Under the row lock Send's forward takes, so a reply posted or an item forwarded during the pass is seen here.
      current = Repo.one!(from c in Conversation, where: c.id == ^conversation.id, lock: "FOR UPDATE")
      current_items = Repo.all(from i in Item, where: i.conversation_id == ^conversation.id)
      closed = for item <- current_items, is_struct(item.forwarded_at, DateTime), do: item.key
      before = Map.new(current_items, &{&1.key, &1})
      # A reply already posted is what the customer has, so a pass never replaces it.
      reply = if is_struct(current.reply_posted_at, DateTime), do: current.reply_text, else: result["reply"]

      kept =
        for {attrs, position} <- Enum.with_index(items, 1), is_map(attrs), attrs["key"] not in closed do
          (Map.get(before, attrs["key"]) || %Item{conversation_id: conversation.id})
          |> Item.agent_changeset(item_attrs(attrs, position, Map.get(issues, attrs["existing_issue"])))
          |> Repo.insert_or_update()
          |> case do
            {:ok, item} ->
              item

            # The result is the agent's: an item Rail cannot save fails the pass and keeps the draft as it was.
            {:error, %Ecto.Changeset{errors: errors}} ->
              Repo.rollback(
                "The agent listed an item Rail could not save: item #{inspect(attrs["key"])}: #{fields(errors)}."
              )
          end
        end

      kept_keys = Enum.map(kept, & &1.key)

      Repo.delete_all(
        from i in Item,
          where: i.conversation_id == ^conversation.id and is_nil(i.forwarded_at) and i.key not in ^kept_keys
      )

      title = if is_binary(result["title"]), do: result["title"]

      current
      |> Ecto.Changeset.change(reply_text: reply, title: current.title || title)
      |> Repo.update!()

      Repo.insert!(%ChatMessage{
        conversation_id: conversation.id,
        author: :agent,
        text: String.slice(result["message"], 0, 4000),
        changes: calculate_changes(current, reply, before, kept)
      })
    end)
  end

  # Each field's error in words, such as "verdict is invalid". With none, the item's evidence or assumptions failed.
  defp fields([]), do: "has evidence or assumptions Rail could not read"

  defp fields(errors),
    do:
      Enum.map_join(errors, ", ", fn {field, {message, _opts}} ->
        "#{String.replace(to_string(field), "_", " ")} #{message}"
      end)

  defp existing_issues(%Project{} = project, items) do
    for identifier <- items |> Enum.map(&(is_map(&1) && &1["existing_issue"])) |> Enum.filter(&is_binary/1) |> Enum.uniq(),
        {:ok, %Issue{id: id}} <- [Issues.import_issue(project, identifier)],
        into: %{},
        do: {identifier, id}
  end

  defp item_attrs(attrs, position, issue_id) do
    issue = if is_map(attrs["issue"]), do: attrs["issue"], else: %{}

    %{
      key: attrs["key"],
      position: position,
      kind: attrs["kind"],
      title: attrs["title"],
      verdict: attrs["verdict"],
      summary: attrs["summary"],
      evidence: List.wrap(attrs["evidence"]),
      assumptions: List.wrap(attrs["assumptions"]),
      existing_issue_id: issue_id,
      issue_title: issue["title"],
      issue_description: issue["description"],
      issue_priority: issue["priority"],
      issue_estimate: issue["estimate"]
    }
  end

  # The one-line note under the agent's answer, such as "Edited the reply · Added item 3".
  defp calculate_changes(%Conversation{reply_text: old_reply}, new_reply, before, kept) do
    edited_reply = if is_binary(old_reply) and old_reply != new_reply, do: "Edited the reply"

    items =
      for item <- kept do
        previous = Map.get(before, item.key)

        cond do
          is_nil(previous) -> "Added item #{item.position}"
          Map.take(item, @compared) != Map.take(previous, @compared) -> "Edited item #{item.position}"
          true -> nil
        end
      end

    case Enum.reject([edited_reply | items], &is_nil/1) do
      [] -> nil
      changes -> Enum.join(changes, " · ")
    end
  end

  defp finish(%Conversation{id: id} = conversation, outcome, started_at) do
    retrying =
      match?({:error, {:waiting_for_usage, _resets_at}}, outcome) or match?({:error, {:mcp_unreachable, _names}}, outcome)

    error =
      case outcome do
        {:ok, %ChatMessage{}} -> nil
        {:error, _reason} when retrying -> nil
        {:error, reason} -> error_message(reason)
      end

    # drafted_at is when the pass began, so a customer message posted while it ran is newer and gets a draft.
    Repo.update_all(from(c in Conversation, where: c.id == ^id),
      set:
        [agent_started_at: nil, mcp_token_hash: nil, agent_error: error] ++
          if(retrying, do: [], else: [drafting_since: nil, drafted_at: started_at])
    )

    # A chat line or customer message that arrived during the pass gets a pass of its own.
    arrived? =
      Repo.exists?(
        from m in ChatMessage, where: m.conversation_id == ^id and m.author == :person and m.inserted_at > ^started_at
      ) or
        Repo.exists?(
          from m in Message, where: m.conversation_id == ^id and m.kind == :customer and m.inserted_at > ^started_at
        )

    if arrived? and is_nil(error) and not retrying, do: {:ok, _conversation} = request_support_draft(conversation)
    Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
  end

  defp error_message({:exit, code, output}) do
    case Tools.agent_failure_reason(output) do
      reason when is_binary(reason) -> "The agent exited with code #{code}: #{reason}"
      nil -> "The agent exited with code #{code}."
    end
  end

  defp error_message(:timeout), do: "The agent was still running after 30 minutes, so it was stopped."
  defp error_message(:dispatch_disabled), do: "Dispatch is switched off, so the agent did not run."

  defp error_message(:backend_signed_out),
    do:
      "The Triage role's backend is signed out, so the agent did not run. Sign it in under Settings → Backends, then try again."

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: "The agent failed: #{inspect(reason)}"

  defp draft(%Conversation{} = conversation) do
    %{
      reply: conversation.reply_text,
      reply_posted: is_struct(conversation.reply_posted_at, DateTime),
      items:
        Enum.map(conversation.items, fn %Item{} = item ->
          %{
            key: item.key,
            state: item_state(item),
            kind: item.kind,
            title: item.title,
            verdict: item.verdict,
            summary: item.summary,
            existing_issue: item.existing_issue && item.existing_issue.identifier,
            issue: %{
              title: item.issue_title,
              description: item.issue_description,
              priority: item.issue_priority,
              estimate: item.issue_estimate
            }
          }
        end)
    }
  end

  defp item_state(%Item{forwarded_at: %DateTime{}}), do: "forwarded, closed to this pass"
  defp item_state(%Item{existing_issue: %Issue{identifier: identifier}}), do: "tracked in #{identifier}"
  defp item_state(%Item{}), do: "to forward"

  defp conversation_file(%Conversation{} = conversation, files_dir) do
    lines =
      Enum.map(conversation.messages, fn %Message{} = message ->
        attached =
          message.attachments
          |> Enum.with_index(1)
          |> Enum.map(&attachment_line(&1, message, conversation, files_dir))

        body = [message.text, Enum.join(attached, "\n")] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
        "### #{message.author_name} (#{who(message.kind)}) · #{DateTime.to_iso8601(message.posted_at)}\n\n#{body}\n"
      end)

    "# Intercom conversation with #{conversation.customer_name || "a customer"}\n\n" <> Enum.join(lines, "\n")
  end

  defp attachment_line({file, n}, %Message{} = message, %Conversation{} = conversation, files_dir) do
    case Intercom.download_file(conversation.intercom_workspace, file.url) do
      {:ok, body} when is_binary(body) ->
        path = Path.join(files_dir, "#{message.external_id}-#{n}-#{Path.basename(file.name || "file")}")
        File.write!(path, body)
        "Attached: #{path} (#{file.name})"

      _unreadable ->
        "Attached, but Rail could not download it: #{file.name}"
    end
  end

  defp who(:customer), do: "customer"
  defp who(:teammate), do: "teammate"
  defp who(:bot), do: "bot"
  defp who(:note), do: "internal note, the customer never saw it"

  defp chat_file(%Conversation{chat_messages: []}), do: "No chat yet. Draft the reply and the forward list.\n"

  defp chat_file(%Conversation{chat_messages: lines}) do
    Enum.map_join(lines, "\n", fn
      %ChatMessage{author: :person, user: user, text: text} -> "### #{person(user)}\n\n#{text}\n"
      %ChatMessage{author: :agent, text: text} -> "### You\n\n#{text}\n"
    end)
  end

  defp person(%{name: name}) when is_binary(name) and name != "", do: name
  defp person(%{login: login}) when is_binary(login), do: login
  defp person(_gone), do: "Support"

  defp brief(%Conversation{} = conversation, role) do
    dir = Conversation.scratch_path(conversation)
    file = Path.join(dir, "result.json")

    String.trim("""
    You are helping a support teammate answer a customer in Intercom. Read #{Path.join(dir, "conversation.md")}: every message, with who wrote it. Files the customer attached are listed under their message with their paths; open every one before you judge the message. Your working directory is a checkout of #{conversation.project.name}'s default branch.

    Read #{Path.join(dir, "draft.json")}, the draft as it stands, with any edits the teammate made to the reply, and #{Path.join(dir, "chat.md")}, your chat with them so far. When the chat ends with a message from them, do what it asks: change only what it asks, keep every verdict as it is unless it asks you to revisit one, and answer it. With no chat yet, draft the reply and the list from the conversation.

    You are reading the code, not changing it: write no code and no files outside #{dir}, and never run a git command that writes. Use any MCP tools you were offered for evidence only; never post, reply, create or change anything with them.

    #{search(conversation)}
    #{rules(conversation, role)}
    Write #{file} last, with a heredoc, the body and its closing JSON line at column zero:

    cat > #{file} <<'JSON'
    {
      "title": "one line naming what the conversation is about",
      "message": "what you tell the teammate in the chat",
      "reply": "the reply to the customer, or null",
      "items": [
        {
          "key": "short-stable-slug",
          "kind": "bug",
          "title": "one line naming the bug or the request",
          "verdict": "confirmed",
          "summary": "the root cause, or how much of the request exists today",
          "evidence": [{"file": "lib/path/to/file.ex", "lines": "42-45", "excerpt": "the line that shows it", "holds": true}],
          "assumptions": [{"text": "what you took as given without checking", "corrected": false}],
          "existing_issue": null,
          "issue": {"title": "the behavior the product should have, once the issue is done", "description": "the problem, its cause and its evidence", "priority": "medium", "estimate": 2}
        }
      ]
    }
    JSON

    - The reply goes to the customer, outside the team, posted under the teammate's name. Write it in their voice, plainly.
    - When draft.json has `reply_posted` true, the customer already has that reply. Return it unchanged as `reply`, change only the list, and tell the teammate in `message` that a new reply needs a new message from the customer.
    - When the customer asks how to do something the product already does, the reply gives the steps, in the words the product's screens use.
    - For anything going to the team, the reply says in general terms that it has been passed on to the dev team. Never promise a fix, a release or a date, and never name a ticket or its identifier.
    - `message` is for the teammate, in two to five short sentences: what you found and what you changed. For every item that already has a ticket, name the ticket's identifier, its title and its current status. The teammate has no other way to see tickets.
    - `items` is every bug and request the conversation raises that the product team should see, each under the same `key` across passes. Items draft.json marks forwarded are closed: never restate them, and anything new about one is a new item with a new key.
    - `kind` is `bug` or `feature_request`. A bug's `verdict` is `confirmed`, `not_reproduced` or `already_fixed`; a request's is `built`, `partly_built` or `not_built`.
    - `existing_issue` is the identifier of the ticket that already covers the item, or null. When one does, leave `issue` null: it is never forwarded.
    - Every item you list goes to the dev team, who decide on it. Drop an item only when the teammate asks you to in the chat.
    - An issue's `title` states the behavior the product should have, as a sentence that is true once the issue is done, never the fault. `priority` is `urgent`, `high`, `medium` or `low`; `estimate` is 1, 2, 3, 5 or 8, or null.
    - Never propose a fix, a design or a plan, anywhere.
    """)
  end

  defp search(%Conversation{project: %Project{tracker: :local}}),
    do:
      "Before you draft any issue, search this project's tickets for one that already covers the item with `search_issues`, which matches by meaning and includes finished tickets. " <>
        "Search at least twice, in the customer's words and then in the names you found in the code. Open a likely match with `get_issue` and read its status before you cite it."

  defp search(%Conversation{project: project}),
    do:
      "Before you draft any issue, search Linear for one that already covers the item, with the Linear tools you were offered, on the #{project.key} team. " <>
        "Include finished issues, try at least two phrasings, and open a likely match to read its status before you cite it."

  defp rules(%Conversation{messages: messages}, role) do
    case Learnings.retrieve_learnings(role, [Enum.map_join(messages, "\n\n", & &1.text)]) do
      [] ->
        ""

      rules ->
        lines =
          Enum.map_join(rules, "\n", fn %Learning{} = rule -> "- #{Learning.kind_label(rule.kind)}: #{rule.rule}" end)

        "\nWhat this project has learned, from people's corrections and decisions. Read a report against these before you call it a bug.\n\n#{lines}\n"
    end
  end
end
