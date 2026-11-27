defmodule Rail.Triage.Actions.TriageThread do
  @moduledoc """
  Runs one triage pass on a thread: an agent reads the thread, the draft, the chat and the
  project's code, and writes one result file that replaces the draft.

  A pass is not a pipeline run, because a thread has no task and no issue. It
  runs the agent to completion in a detached checkout of the default branch,
  under a lock on the thread that also makes the pass's MCP token valid.

  Nothing here reaches Slack beyond reading the thread, and a tracker only through
  the searches the agent runs for existing issues: only a person's Send posts or
  creates anything.
  """

  import Ecto.Query
  import Rail.Triage.Utils.EnqueueTriage
  import Rail.Triage.Utils.SettleThread
  import Rail.Triage.Utils.UpsertSlackMessage

  alias Rail.Git
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Slack
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  @stale_after_minutes 45
  @timeout to_timeout(minute: 30)

  @doc """
  Triages `thread`. Returns `:ok`, `{:snooze, 30}` when another pass holds it, one of the
  role's MCP servers did not answer or a Send held it when the result came in, or
  `{:waiting_for_usage, resets_at}` when every account is used up, none of which is a
  failure. A pass that fails records why on the thread and leaves the draft as it was.
  """
  def triage_thread(%Thread{id: thread_id}) do
    {token, hash} = Mcp.issue_run_token()
    started_at = DateTime.utc_now()
    stale = DateTime.shift(started_at, minute: -@stale_after_minutes)

    {claimed, _rows} =
      Repo.update_all(
        from(t in Thread,
          where: t.id == ^thread_id and (is_nil(t.triage_started_at) or t.triage_started_at < ^stale)
        ),
        set: [triage_started_at: started_at, mcp_token_hash: hash]
      )

    if claimed == 1, do: run(Repo.get!(Thread, thread_id), token, started_at), else: {:snooze, 30}
  end

  defp run(%Thread{} = thread, token, started_at) do
    thread = Repo.preload(thread, [:project, slack_channel: :slack_workspace])

    outcome =
      try do
        pass(thread, token, started_at)
      after
        _removed = Git.remove_worktree(thread.project.clone_path, Thread.worktree_path(thread))
      end

    finish(thread, outcome)
    :ok = release(thread, started_at)

    case outcome do
      {:error, {:waiting_for_usage, resets_at}} -> {:waiting_for_usage, resets_at}
      {:error, {:mcp_unreachable, _names}} -> {:snooze, 30}
      # A Send held the thread when the result came in; the messages and chat stay unread, so the retry reads them.
      {:error, :sending} -> {:snooze, 30}
      _ran_or_failed -> :ok
    end
  end

  defp pass(thread, token, started_at) do
    with :ok <- backfill(thread),
         thread = load(thread),
         :ok <- owed(thread),
         {:ok, role} <- role(thread),
         :ok <- check_tools(thread, role),
         :ok <- write_files(thread),
         {:ok, worktree} <- Git.checkout_detached_worktree(thread.project, Thread.worktree_path(thread)),
         {:ok, _output} <- agent(thread, role, worktree, token),
         %{rejected: []} = result <- Triage.read_triage(thread) || {:error, :unreadable} do
      Triage.sync_triage(thread, result, started_at)
    else
      %{rejected: keys} ->
        {:error, "Triage listed an item Rail could not read: #{Enum.join(keys, ", ")}. The draft is as it was."}

      other ->
        other
    end
  end

  # A forwarded thread has no Slack thread to read.
  defp backfill(%Thread{slack_channel: nil}), do: :ok

  defp backfill(%Thread{slack_channel: %{slack_workspace: workspace} = channel} = thread) do
    with {:ok, replies} <- Slack.replies(workspace, channel.external_id, thread.external_id),
         {:ok, permalink} <- permalink(thread) do
      _names =
        Enum.reduce(replies, %{}, fn reply, names ->
          {:ok, _message, names} = upsert_slack_message(thread, workspace, reply, names)
          names
        end)

      if permalink != thread.permalink, do: thread |> Ecto.Changeset.change(permalink: permalink) |> Repo.update!()
      :ok
    else
      {:error, {:slack_error, reason}} -> {:error, {:slack, reason}}
      {:error, reason} -> {:error, {:slack, inspect(reason)}}
    end
  end

  defp permalink(%Thread{permalink: permalink}) when is_binary(permalink), do: {:ok, permalink}

  defp permalink(%Thread{slack_channel: channel} = thread) do
    Slack.permalink(channel.slack_workspace, channel.external_id, thread.external_id)
  end

  defp load(thread) do
    thread
    |> Repo.reload!()
    |> Repo.preload(
      project: :triage_user,
      slack_channel: :slack_workspace,
      messages: from(m in Message, order_by: [asc: m.posted_at, asc: m.id]),
      items: from(i in Item, order_by: [asc: i.position, asc: i.id], preload: :existing_issue),
      chat_messages: from(c in ChatMessage, order_by: [asc: c.inserted_at, asc: c.id], preload: :user)
    )
  end

  defp owed(%Thread{} = thread) do
    if Enum.any?(thread.messages, &(is_nil(&1.triaged_at) and Thread.triggering?(thread, &1))) or
         Thread.chat_owed?(thread),
       do: :ok,
       else: :nothing
  end

  defp role(%Thread{project_id: project_id}) do
    case Roles.get_role(project_id: project_id, stage: :triage) do
      {:ok, role} -> {:ok, role}
      {:error, :role_not_found} -> {:error, :no_role}
    end
  end

  # A role's MCP servers are part of the pass, so a pass without them would draft a worse answer rather than fail: it is
  # stopped here,
  # saying what to fix before a retry. A server that did not answer is no
  # failure: the pass is tried again until it does.
  defp check_tools(%Thread{project: project}, role) do
    case Mcp.check_run_tools(%RunContext{role: role, user: project.triage_user}) do
      :ok -> :ok
      {:error, {:mcp_unreachable, _names}} = unreachable -> unreachable
      {:error, reason} -> {:error, tools_error(reason, project.triage_user)}
    end
  end

  defp tools_error({:mcp_reconnect, names}, nil),
    do:
      "This project has no triage user to reach #{Enum.join(names, ", ")} as. " <>
        "Pick one under Settings → Projects, then ask the agent in the chat to try again."

  defp tools_error({:mcp_reconnect, names}, %User{} = user),
    do:
      "#{Enum.join(names, ", ")} needs reconnecting for #{user.name || user.login}. " <>
        "Reconnect it under Settings → Connected accounts, then ask the agent in the chat to try again."

  defp write_files(%Thread{} = thread) do
    dir = Thread.scratch_path(thread)
    File.mkdir_p!(dir)
    File.rm(Path.join(dir, "result.json"))
    images_dir = Path.join(dir, "images")
    File.rm_rf!(images_dir)
    File.mkdir_p!(images_dir)

    images =
      Map.new(thread.messages, fn %Message{} = message ->
        {message.id, message.images |> Enum.with_index(1) |> Enum.map(&image_file(&1, message, thread, images_dir))}
      end)

    File.write!(Path.join(dir, "thread.md"), thread_file(thread, images))
    File.write!(Path.join(dir, "draft.json"), Jason.encode!(draft(thread), pretty: true))
    File.write!(Path.join(dir, "chat.md"), chat_file(thread))
    :ok
  end

  defp image_file({%Message.Image{url: url} = image, n}, %Message{} = message, %Thread{} = thread, dir)
       when is_binary(url) do
    case Slack.download_file(thread.slack_channel.slack_workspace, url) do
      {:ok, body} ->
        path = Path.join(dir, "#{message.external_id}-#{n}.#{List.first(MIME.extensions(image.mimetype), "img")}")
        File.write!(path, body)
        {:ok, path, image}

      {:error, _unreadable} ->
        {:unreadable, image}
    end
  end

  defp image_file({%Message.Image{} = image, _n}, _message, _thread, _dir), do: {:unreadable, image}

  defp agent(%Thread{} = thread, role, worktree, token) do
    prompt =
      Pipeline.build_prompt(context_snippet: brief(thread, role))

    args =
      Tools.build_args(
        prompt: prompt,
        model: role.model,
        reasoning_effort: to_string(role.reasoning_effort || :high),
        system_prompt: role.system_prompt,
        work_dir: worktree
      )

    # It reads the thread and writes its result in the scratch folder, and only reads the code.
    Tools.run_agent(role, args,
      env: %{"RAIL_MCP_TOKEN" => token},
      cd: worktree,
      mounts: [Thread.scratch_path(thread)],
      read_only_mounts: [worktree],
      timeout: @timeout
    )
  end

  defp finish(thread, {:ok, %Thread{}}),
    do: thread |> Repo.reload!() |> Ecto.Changeset.change(error: nil) |> Repo.update!()

  defp finish(_thread, :nothing), do: :ok
  defp finish(_thread, {:error, {:waiting_for_usage, _resets_at}}), do: :ok
  defp finish(_thread, {:error, {:mcp_unreachable, _names}}), do: :ok
  defp finish(_thread, {:error, :sending}), do: :ok

  defp finish(%Thread{} = thread, {:error, reason}),
    do: thread |> Repo.reload!() |> Ecto.Changeset.change(error: error_message(reason)) |> Repo.update!()

  defp release(%Thread{id: thread_id} = thread, started_at) do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [triage_started_at: nil, mcp_token_hash: nil])
    {:ok, settled} = settle_thread(thread)

    arrived =
      Repo.all(
        from m in Message, where: m.thread_id == ^thread_id and is_nil(m.triaged_at) and m.inserted_at > ^started_at
      )

    # A chat line sent while the pass ran is newer than the stamp, and gets a pass of its own.
    chatted? =
      Repo.exists?(
        from c in ChatMessage,
          where: c.thread_id == ^thread_id and c.author == :person and c.inserted_at > ^started_at
      )

    settled = Repo.preload(settled, slack_channel: :slack_workspace)

    if is_nil(settled.error) and (chatted? or Enum.any?(arrived, &Thread.triggering?(settled, &1))),
      do: enqueue_triage(settled)

    :ok
  end

  defp error_message(:no_role), do: "This project has no Triage role."

  defp error_message({:exit, code, output}) do
    case Tools.agent_failure_reason(output) do
      reason when is_binary(reason) -> "Triage exited with code #{code}: #{reason}"
      nil -> "Triage exited with code #{code}."
    end
  end

  defp error_message(:timeout), do: "Triage was still running after 30 minutes, so it was stopped."
  defp error_message(:dispatch_disabled), do: "Dispatch is switched off, so triage did not run."

  defp error_message(:backend_signed_out),
    do:
      "The Triage role's backend is signed out, so triage did not run. " <>
        "Sign it in under Settings → Backends, then ask the agent in the chat to try again."

  defp error_message(:unreadable), do: "Triage finished without writing a result Rail could read."
  defp error_message({:slack, reason}), do: "Could not read the thread from Slack: #{reason}"
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: "Triage failed: #{inspect(reason)}"

  defp thread_file(%Thread{} = thread, images) do
    lines =
      Enum.map(thread.messages, fn %Message{} = message ->
        who =
          cond do
            Message.via_rail?(message) -> "#{message.author_name} (teammate, posted through Rail)"
            message.from_bot -> "#{message.author_name} (bot)"
            true -> message.author_name
          end

        attached =
          Enum.map(Map.fetch!(images, message.id), fn
            {:ok, path, image} ->
              "Image attached: #{path} (#{image.name})"

            {:unreadable, %{mimetype: mimetype, name: name}} when is_binary(mimetype) ->
              "Image attached, but Rail could not read it: #{name}"

            {:unreadable, _withheld} ->
              "A file was attached, but Rail could not read it."
          end)

        body = [message.text, Enum.join(attached, "\n")] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

        "### #{message.external_id} · #{who} · #{DateTime.to_iso8601(message.posted_at)}\n\n#{body}\n"
      end)

    "# #{Thread.link_label(thread)} in #{Thread.source_label(thread)}\n\n" <> Enum.join(lines, "\n")
  end

  defp draft(%Thread{} = thread) do
    %{
      reply: thread.reply_text,
      reply_posted: is_struct(thread.reply_posted_at, DateTime),
      items:
        Enum.map(thread.items, fn %Item{} = item ->
          %{
            key: item.key,
            position: item.position,
            state: item_state(item),
            kind: item.kind,
            title: item.title,
            verdict: Item.fitting_verdict(item),
            summary: item.summary,
            evidence: Enum.map(item.evidence, &Map.from_struct/1),
            assumptions: Enum.map(item.assumptions, &Map.from_struct/1),
            existing_issue: item.existing_issue && item.existing_issue.identifier,
            issue_note: item.issue_note,
            followup: item.followup_text,
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

  defp item_state(%Item{} = item) do
    cond do
      Item.closed?(item) -> "closed: never restate it"
      item.ignored -> "ignored by a teammate: restate it unchanged unless the chat asks"
      true -> "open"
    end
  end

  defp chat_file(%Thread{chat_messages: []}), do: "No chat yet.\n"

  defp chat_file(%Thread{chat_messages: lines}) do
    Enum.map_join(lines, "\n", fn
      %ChatMessage{author: :person, user: user, text: text} -> "### #{person(user)}\n\n#{text}\n"
      %ChatMessage{author: :agent, text: text} -> "### You\n\n#{text}\n"
    end)
  end

  defp person(%{name: name}) when is_binary(name) and name != "", do: name
  defp person(%{login: login}) when is_binary(login), do: login
  defp person(_gone), do: "A teammate"

  defp brief(%Thread{} = thread, role) do
    dir = Thread.scratch_path(thread)
    file = Path.join(dir, "result.json")

    String.trim("""
    Triage the #{Thread.link_label(thread)} in #{Path.join(dir, "thread.md")}. Images attached to a message are listed under it in thread.md with their paths: open every one before you judge the message, because a screenshot is often the report itself. Where thread.md says an attachment could not be read, the message still carried one, so never mark it as needing no response for having no text. Your working directory is a checkout of #{thread.project.name}'s default branch, and every path you read is under it.

    Read #{Path.join(dir, "draft.json")}, the draft as it stands, with any edits a teammate made to the reply and the tickets, and #{Path.join(dir, "chat.md")}, your chat with the team so far. When the chat ends with a teammate's message, do what it asks and answer it: change only what it asks, and keep every other item, verdict and field exactly as draft.json has it, evidence and assumptions included. When no message is waiting, read the thread and draft the reply and the tickets.
    #{forwarded(thread)}
    You are reading the code, not changing it: write no code, no tests and no files outside #{dir}, and never run a git command that writes. Run a single targeted check only where it settles a question reading cannot, and say in the evidence what you ran. Use any MCP tools you were offered for evidence only; never use one to post, reply, comment, create or change anything.

    A message thread.md marks as a teammate's, posted through Rail, is the team's own earlier reply. It is context, and never needs a response of its own.

    You have the code and nothing else: no production data, logs or application state. Where a bug turns on something you cannot see, reason from the code and state what you could not check as an assumption.

    #{search(thread)}
    #{rules(thread, role)}
    Writing #{file} is how you report, and it is the last thing you do. Write it with a heredoc, the body and its closing JSON line at column zero:

    cat > #{file} <<'JSON'
    {
      "title": "one line naming what the thread is about",
      "message": "what you tell the team in the chat: what you found and what you changed, in two to five short sentences",
      "reply": "one reply a teammate would post in the thread, covering every item, or null to leave the reply as it is",
      "messages": [
        {
          "ts": "the message's ts from thread.md",
          "needs_response": true,
          "reason": "why it needs no response, when it needs none",
          "items": [
            {"key": "short-stable-slug", "change": "raised", "passage": "the exact words from the message that raised or changed the item"}
          ]
        }
      ],
      "items": [
        {
          "key": "short-stable-slug",
          "kind": "bug",
          "title": "one line naming the bug or the request",
          "verdict": "confirmed",
          "summary": "the root cause, or how much of the request exists today",
          "evidence": [
            {"file": "lib/path/to/file.ex", "lines": "42-45", "excerpt": "the line that shows it", "holds": true}
          ],
          "assumptions": [{"text": "what you took as given without checking", "corrected": false}],
          "existing_issue": null,
          "issue_note": "which issue you checked covers this, or that none does",
          "followup": "for an item an existing issue covers: what this thread adds to that issue, or null",
          "issue": {"title": "the behavior the product should have, once the issue is done", "description": "the problem, its cause and its evidence", "priority": "medium", "estimate": 2}
        }
      ]
    }
    JSON

    - List every message from thread.md under `messages`. `needs_response` is false for a message that asks and reports nothing, in its text or its images, with the one-line `reason`.
    - `items` is the whole list. Restate every item draft.json marks open or ignored under its key, and leave out an open item only to drop it or to merge it into another. Never restate a closed item: anything new about one is a new item with a new key. Raise none for a thread that needs no response: `"items": []` is the right answer then.
    - `key` is your name for the item, lowercase with hyphens, and it stays the same across passes. That is what lets a later message widen or narrow an item rather than raise it twice.
    - `change` is `raised` for the message that first brought an item up, `widened` or `narrowed` when a later message changes its scope, and `added` for a new item raised later in the thread. `passage` is quoted verbatim from the message.
    - `kind` is `bug` or `feature_request`. A bug's `verdict` is `confirmed`, `not_reproduced` or `already_fixed`; a request's is `built`, `partly_built` or `not_built`.
    - A null `verdict` in draft.json means a teammate changed the item's kind. Judge it again, with a verdict that fits the kind.
    - Never propose a fix, a design or a plan, anywhere. There is no field for one.
    - An issue's `title` states the behavior the product should have, as a sentence that is true once the issue is done, never what goes wrong today: "Saving a draft keeps its attachments", not "Attachments are lost when saving a draft". A title naming the fault reads as the behavior wanted, so whoever picks it up builds the bug. It says what should happen, not how to make it happen. The `description` is where the problem, its cause and its evidence go.
    - `existing_issue` is the identifier of the issue that already covers the item, such as `#{thread.project.key}-23`, or null. When one does, leave `issue` null, and #{tracked(thread)}
    - When `existing_issue` names an issue, write a `followup` only if the thread adds something that issue does not already say: a new case, a new symptom, who else hit it. Write it for that issue's readers, in two or three sentences, and leave it null otherwise. Rail adds it to the issue as a comment, with a link to the thread.
    - `priority` is `urgent`, `high`, `medium` or `low`.
    - `estimate` is the issue's points on Product's scale: 1, 2, 3 or 5, and 8 for work too big for one ticket. Judge it from how much of the behavior exists and what the code shows, or leave it null where you cannot. It is a number only, never a description of the work.
    - The reply is posted by the teammate who sends it, under their name. Write it in their voice. #{links(thread)} Leave `reply` null where only a bot would read it.
    - When draft.json has `reply_posted` true, Slack already has that reply. Write a new `reply` only for a message in the thread newer than it; otherwise leave `reply` null.
    """)
  end

  defp forwarded(%Thread{support_conversation_id: id}) when is_binary(id),
    do: "\nSupport already answered this customer in Intercom. Leave `reply` null.\n"

  defp forwarded(%Thread{}), do: ""

  defp search(%Thread{}),
    do:
      "Before you draft any issue, search this project's tickets for one that already covers the item. " <>
        "Search them with `search_issues`, which matches by meaning and includes finished and archived tickets. Search at least twice, " <>
        "first describing the problem in the thread's own words and then in the names you found in the code, before you decide none does. " <>
        "Open a likely match with `get_issue` and read it before you cite it, and give `existing_issue` exactly as the search showed it."

  # People outside the team read an external channel's replies, so they never point into the tracker.
  defp tracked(%Thread{slack_channel: %{external: true}}),
    do:
      "the reply says the item is already tracked, without naming the issue or its identifier. Still fill in `existing_issue`: only teammates see it."

  defp tracked(%Thread{}),
    do: "the reply says the item is already tracked in that issue, giving its identifier and its current state."

  defp links(%Thread{slack_channel: %{external: true}}),
    do:
      "This thread's channel is external, shared with people outside the team: never name an issue or its identifier in the reply."

  defp links(%Thread{}),
    do:
      "One reply covers every item in the thread. Rail ends it with the links of the tickets it creates, so never write a link or a ticket identifier for a ticket you are drafting."

  # A pass is not a run, so what it was given is not logged.
  defp rules(%Thread{messages: messages}, role) do
    case Learnings.retrieve_learnings(role, [Enum.map_join(messages, "\n\n", & &1.text)]) do
      [] ->
        ""

      rules ->
        lines =
          Enum.map_join(rules, "\n", fn %Learning{} = rule ->
            why = if rule.why, do: " Why: #{String.replace(rule.why, "\n", " ")}", else: ""
            "- #{Learning.kind_label(rule.kind)}: #{rule.rule}#{why}"
          end)

        """

        What this project has learned, from people's corrections and decisions: duplicates, behavior that is expected, rulings already made. Read a report against these before you call it a bug.

        #{lines}
        """
    end
  end
end
