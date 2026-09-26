defmodule Rail.Triage.Actions.TriageThread do
  @moduledoc """
  Runs one triage pass on a thread: an agent reads the thread and the project's
  code and writes one result file, which is folded into the thread's items.

  A pass is not a pipeline run, because a thread has no task and no issue. It
  runs the agent to completion in a detached checkout of the default branch,
  under a lock on the thread that also makes the pass's MCP token valid.

  Nothing here reaches Slack beyond reading the thread, and nothing reaches
  Linear: only a person accepting a proposal posts or creates anything.
  """

  import Ecto.Query
  import Rail.Triage.Utils.EnqueueTriage
  import Rail.Triage.Utils.SettleThread
  import Rail.Triage.Utils.UpsertSlackMessage

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Mcp
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Slack
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Triage.Schemas.Correction
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @stale_after_minutes 45
  @timeout to_timeout(minute: 30)

  @doc """
  Triages `thread`. Returns `:ok`, or `{:snooze, 30}` when another pass holds it.
  A pass that fails records why on the thread and leaves its items as they were.
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
        pass(thread, token)
      after
        _removed = Git.remove_worktree(thread.project.clone_path, Thread.worktree_path(thread))
      end

    finish(thread, outcome)
    release(thread, started_at)
  end

  defp pass(thread, token) do
    with :ok <- backfill(thread),
         thread = load(thread),
         {:ok, keys} <- pass_scope(thread),
         {:ok, role} <- role(thread),
         :ok <- write_files(thread),
         {:ok, worktree} <- Git.checkout_detached_worktree(thread.project, Thread.worktree_path(thread)),
         {:ok, _output} <- agent(thread, role, worktree, token),
         %{} = result <- Triage.read_triage(thread) || {:error, :unreadable} do
      Triage.sync_triage(thread, result, keys)
    end
  end

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
    |> Repo.preload([
      :project,
      slack_channel: :slack_workspace,
      messages: from(m in Message, order_by: [asc: m.posted_at]),
      items: from(i in Item, order_by: [asc: i.position]),
      corrections: from(c in Correction, order_by: [asc: c.inserted_at], preload: :item)
    ])
  end

  # New messages put every open item in play and allow new ones; a correction
  # with nothing new puts only the corrected items back.
  defp pass_scope(%Thread{} = thread) do
    cond do
      Enum.any?(thread.messages, &(is_nil(&1.triaged_at) and Thread.triggering?(thread, &1))) ->
        {:ok, for(item <- thread.items, not Item.settled?(item), do: item.key)}

      Enum.any?(thread.items, & &1.retriaging) ->
        {:ok, for(item <- thread.items, item.retriaging, do: item.key)}

      true ->
        :nothing
    end
  end

  defp role(%Thread{project_id: project_id}) do
    case Roles.get_role(project_id: project_id, stage: :triage) do
      {:ok, role} -> {:ok, role}
      {:error, :role_not_found} -> {:error, :no_role}
    end
  end

  defp write_files(%Thread{} = thread) do
    dir = Thread.scratch_path(thread)
    File.mkdir_p!(dir)
    File.rm(Path.join(dir, "result.json"))
    File.write!(Path.join(dir, "thread.md"), thread_file(thread))
    File.write!(Path.join(dir, "issues.md"), issues_file(thread))
    :ok
  end

  defp agent(%Thread{} = thread, role, worktree, token) do
    prompt =
      Pipeline.build_prompt(backend: role.backend, role_instructions: role.system_prompt, context_snippet: brief(thread))

    args =
      Tools.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: to_string(role.reasoning_effort || :high),
        system_prompt: role.system_prompt,
        work_dir: worktree
      )

    Tools.run_agent(role.backend, args, env: %{"RAIL_MCP_TOKEN" => token}, cd: worktree, timeout: @timeout)
  end

  defp finish(thread, {:ok, %Thread{}}) do
    thread |> Repo.reload!() |> Ecto.Changeset.change(error: nil, forced: false) |> Repo.update!()
  end

  defp finish(_thread, :nothing), do: :ok

  defp finish(%Thread{id: thread_id} = thread, {:error, reason}) do
    Repo.update_all(from(i in Item, where: i.thread_id == ^thread_id and i.retriaging), set: [retriaging: false])
    thread |> Repo.reload!() |> Ecto.Changeset.change(error: error_message(reason)) |> Repo.update!()
  end

  defp release(%Thread{id: thread_id} = thread, started_at) do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [triage_started_at: nil, mcp_token_hash: nil])
    {:ok, settled} = settle_thread(thread)

    arrived =
      Repo.all(
        from m in Message, where: m.thread_id == ^thread_id and is_nil(m.triaged_at) and m.inserted_at > ^started_at
      )

    settled = Repo.preload(settled, slack_channel: :slack_workspace)
    if is_nil(settled.error) and Enum.any?(arrived, &Thread.triggering?(settled, &1)), do: enqueue_triage(settled)

    :ok
  end

  defp error_message(:no_role), do: "This project has no Triage role."
  defp error_message({:exit, code}), do: "Triage exited with code #{code}."
  defp error_message(:timeout), do: "Triage was still running after 30 minutes, so it was stopped."
  defp error_message(:dispatch_disabled), do: "Dispatch is switched off, so triage did not run."
  defp error_message(:unreadable), do: "Triage finished without writing a result Rail could read."
  defp error_message({:slack, reason}), do: "Could not read the thread from Slack: #{reason}"
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: "Triage failed: #{inspect(reason)}"

  defp thread_file(%Thread{} = thread) do
    lines =
      Enum.map(thread.messages, fn %Message{} = message ->
        who =
          cond do
            Message.via_rail?(message) -> "#{message.author_name} (teammate, posted through Rail)"
            message.from_bot -> "#{message.author_name} (bot)"
            true -> message.author_name
          end

        "### #{message.external_id} · #{who} · #{DateTime.to_iso8601(message.posted_at)}\n\n#{message.text}\n"
      end)

    "# Slack thread in ##{thread.slack_channel.name}\n\n" <> Enum.join(lines, "\n")
  end

  defp issues_file(%Thread{project_id: project_id}) do
    %{issues: issues} = Issues.list_issues(project_id: project_id, show_finished: true)

    entries =
      Enum.map(issues, fn %Issue{} = issue ->
        "## #{issue.identifier} · #{Issue.state_label(issue.state)} · #{issue.title}\n\n#{issue.description}\n"
      end)

    "# Every issue in this project\n\n" <> Enum.join(entries, "\n")
  end

  defp brief(%Thread{} = thread) do
    dir = Thread.scratch_path(thread)
    file = Path.join(dir, "result.json")

    String.trim("""
    Triage the Slack thread in #{Path.join(dir, "thread.md")}. Your working directory is a checkout of #{thread.project.name}'s default branch, and every path you read is under it.

    You are reading the code, not changing it: write no code, no tests and no files outside #{dir}, and never run a git command that writes. Run a single targeted check only where it settles a question reading cannot, and say in the evidence what you ran. Use any MCP tools you were offered for evidence only; never use one to post, reply, create or change anything.

    #{Path.join(dir, "issues.md")} lists every issue in this project with its state. Read it before you draft any issue.
    #{forced(thread)}
    #{items(thread)}
    #{corrections(thread)}
    Writing #{file} is how you report, and it is the last thing you do. Write it with a heredoc, the body and its closing JSON line at column zero:

    cat > #{file} <<'JSON'
    {
      "title": "one line naming what the thread is about",
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
          "issue": {"title": "the issue's title", "description": "the problem, its cause and its evidence", "priority": "medium"},
          "reply": "the reply a teammate would post in the thread, or null"
        }
      ]
    }
    JSON

    - List every message from thread.md under `messages`. `needs_response` is false for a message that asks and reports nothing, with the one-line `reason`.
    - `items` is every item this pass restates or raises. Raise none for a thread that needs no response: `"items": []` is the right answer then.
    - `key` is your name for the item, lowercase with hyphens, and it stays the same across passes. That is what lets a later message widen or narrow an item rather than raise it twice.
    - `change` is `raised` for the message that first brought an item up, `widened` or `narrowed` when a later message changes its scope, and `added` for a new item raised later in the thread. `passage` is quoted verbatim from the message.
    - `kind` is `bug` or `feature_request`. A bug's `verdict` is `confirmed`, `not_reproduced` or `already_fixed`; a request's is `built`, `partly_built` or `not_built`.
    - Never propose a fix, a design or a plan, anywhere. There is no field for one.
    - `existing_issue` is the identifier of the issue in issues.md that already covers the item, or null. When one does, leave `issue` null, and the reply says the item is already tracked in that issue, giving its identifier and its state from issues.md.
    - `priority` is `urgent`, `high`, `medium` or `low`.
    - A reply is posted by the teammate who accepts it, under their name. Write it in their voice. Where the issue you draft should be linked, write `{issue link}` and Rail fills it in once the issue exists. Leave `reply` null where only a bot would read it.
    """)
  end

  defp forced(%Thread{forced: true}),
    do:
      "\nA person asked for this thread to be triaged, having seen it marked as needing no response. Read it again closely.\n"

  defp forced(%Thread{}), do: ""

  defp items(%Thread{items: []}), do: ""

  defp items(%Thread{items: items}) do
    lines =
      Enum.map(items, fn %Item{} = item ->
        state = if Item.settled?(item), do: "settled, closed to this pass", else: "open"

        "- `#{item.key}` (#{state}) #{Item.kind_label(item.kind)}: #{item.title}. Verdict: #{Item.verdict_label(item.verdict)}."
      end)

    """

    Earlier passes raised these items. Restate each open one under its key with what you find now. A settled item has been accepted by a person and is closed: never restate it, and anything new about it is a new item with a new key.

    #{Enum.join(lines, "\n")}
    """
  end

  defp corrections(%Thread{corrections: corrections, items: items}) do
    open = for item <- items, item.retriaging, do: item.id

    case Enum.filter(corrections, &(&1.item_id in open)) do
      [] ->
        ""

      pending ->
        lines =
          Enum.map(pending, fn %Correction{} = correction ->
            answering =
              if correction.assumption, do: " It answers your assumption: \"#{correction.assumption}\".", else: ""

            "- On `#{correction.item.key}`, a person wrote: \"#{correction.text}\".#{answering}"
          end)

        """

        A person corrected these items. Triage each of them again with the correction taken as true, restate it under the same key, and mark the assumption it answers `"corrected": true`.

        #{Enum.join(lines, "\n")}
        """
    end
  end
end
