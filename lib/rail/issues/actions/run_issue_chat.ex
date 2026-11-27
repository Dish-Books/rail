defmodule Rail.Issues.Actions.RunIssueChat do
  @moduledoc """
  Runs the agent once on an issue's chat: it reads the ticket, its comments and the chat against the code and the
  project's tickets, answers the last message, and may rewrite the ticket's title, description, priority or estimate.
  """

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues.Schemas.ChatMessage
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools

  @stale_after_minutes 45
  @timeout to_timeout(minute: 30)
  # In the order the note names them: {result key, field, the note when it is written, its name}.
  @fields [
    {"title", :title, "Edited the title", "title"},
    {"description", :description, "Edited the description", "description"},
    {"priority", :priority, "Changed the priority", "priority"},
    {"estimate", :estimate, "Changed the estimate", "estimate"}
  ]

  @doc """
  Returns `:ok`, without a pass when nobody asked, or `{:snooze, seconds}` when another pass holds the issue, an MCP
  server did not answer, or every account is used up. A failed pass leaves the ticket as it was.
  """
  def run_issue_chat(%Issue{id: id}) do
    {token, hash} = Mcp.issue_run_token()
    started_at = DateTime.utc_now()
    stale = DateTime.shift(started_at, minute: -@stale_after_minutes)

    # Only an issue someone asked about: a retried or rescued job whose pass already finished runs nothing.
    {claimed, _rows} =
      Repo.update_all(
        from(i in Issue,
          where:
            i.id == ^id and not is_nil(i.chat_requested_at) and
              (is_nil(i.chat_started_at) or i.chat_started_at < ^stale)
        ),
        set: [chat_started_at: started_at, chat_token_hash: hash]
      )

    cond do
      claimed == 1 -> run(Repo.get!(Issue, id), token)
      Repo.exists?(from i in Issue, where: i.id == ^id and not is_nil(i.chat_requested_at)) -> {:snooze, 30}
      true -> :ok
    end
  end

  defp run(%Issue{} = issue, token) do
    issue = load(issue)

    outcome =
      try do
        pass(issue, token)
      rescue
        # A crash still reaches Sentry, but never leaves the chat stuck on Running.
        exception ->
          finish(issue, {:error, "The agent's pass crashed: #{Exception.message(exception)}"})
          reraise exception, __STACKTRACE__
      after
        _removed = Git.remove_worktree(issue.project.clone_path, worktree_path(issue))
      end

    finish(issue, outcome)

    case outcome do
      {:error, {:waiting_for_usage, resets_at}} -> {:snooze, max(DateTime.diff(resets_at, DateTime.utc_now()), 30)}
      {:error, {:mcp_unreachable, _names}} -> {:snooze, 30}
      _ran_or_failed -> :ok
    end
  end

  defp pass(issue, token) do
    with {:ok, role} <- role(issue),
         :ok <- check_tools(issue, role),
         :ok <- write_files(issue),
         {:ok, worktree} <- Git.checkout_detached_worktree(issue.project, worktree_path(issue)),
         {:ok, _output} <- agent(issue, role, worktree, token),
         {:ok, result} <- read_result(issue) do
      apply_result(issue, result)
    end
  end

  defp load(issue) do
    Repo.preload(issue,
      project: :triage_user,
      comments: from(c in Comment, order_by: [asc: c.inserted_at, asc: c.id]),
      chat_messages: from(m in ChatMessage, order_by: [asc: m.inserted_at, asc: m.id], preload: :user)
    )
  end

  defp role(%Issue{project_id: project_id}) do
    case Roles.get_role(project_id: project_id, stage: :triage) do
      {:ok, role} -> {:ok, role}
      {:error, :role_not_found} -> {:error, "This project has no Triage role, which the issue chat runs on."}
    end
  end

  defp check_tools(%Issue{project: project}, role) do
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

  defp write_files(%Issue{} = issue) do
    dir = scratch_path(issue)
    File.mkdir_p!(dir)
    File.rm(Path.join(dir, "result.json"))
    File.write!(Path.join(dir, "issue.md"), issue_file(issue))
    File.write!(Path.join(dir, "chat.md"), chat_file(issue))
    :ok
  end

  defp agent(%Issue{} = issue, role, worktree, token) do
    args =
      Tools.build_args(
        prompt: Pipeline.build_prompt(context_snippet: brief(issue, role)),
        model: role.model,
        reasoning_effort: to_string(role.reasoning_effort || :high),
        system_prompt: role.system_prompt,
        work_dir: worktree
      )

    # It reads the ticket and the chat and writes its result in the scratch folder, and only reads the code.
    Tools.run_agent(role, args,
      env: %{"RAIL_MCP_TOKEN" => token},
      cd: worktree,
      mounts: [scratch_path(issue)],
      read_only_mounts: [worktree],
      timeout: @timeout
    )
  end

  defp read_result(issue) do
    with {:ok, body} <- File.read(Path.join(scratch_path(issue), "result.json")),
         {:ok, %{"message" => message} = result} when is_binary(message) <- Jason.decode(body) do
      {:ok, %{message: message, ticket: if(is_map(result["ticket"]), do: result["ticket"], else: %{})}}
    else
      _unreadable -> {:error, "The agent finished without writing a result Rail could read."}
    end
  end

  # Under the issue's row lock, which EditIssue and creating a task wait on, so their writes are seen here.
  defp apply_result(%Issue{} = read, %{message: message, ticket: ticket}) do
    {:ok, {line, edited}} =
      Repo.transaction(fn ->
        current = from(i in Issue, where: i.id == ^read.id, lock: "FOR UPDATE") |> Repo.one!() |> Repo.preload(:task)
        {attrs, notes} = calculate_edits(read, current, ticket)
        if attrs != %{}, do: current |> Issue.edit_changeset(attrs) |> Repo.update!()

        line =
          Repo.insert!(%ChatMessage{
            issue_id: current.id,
            author: :agent,
            text: String.slice(message, 0, 4000),
            changes: if(notes == [], do: nil, else: Enum.join(notes, " · "))
          })

        {line, attrs != %{}}
      end)

    if edited, do: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, read.id})
    {:ok, line}
  end

  # A task started during the pass reads the ticket as it stood, so the pass keeps every field.
  defp calculate_edits(%Issue{} = read, %Issue{} = current, ticket) do
    {attrs, notes} = Enum.reduce(@fields, {%{}, []}, &calculate_edit(&1, &2, read, current, ticket))

    if is_struct(current.task) and attrs != %{},
      do: {%{}, ["Left the ticket as it was: a task had started"]},
      else: {attrs, Enum.reverse(notes)}
  end

  # A field is written only while it reads as it did when the pass began, and only with a value the page could set.
  # The notes are gathered newest first.
  defp calculate_edit({key, field, edited, name}, {attrs, notes}, read, current, ticket) do
    value = Map.get(ticket, key, :unchanged)

    cond do
      value == :unchanged or same?(value, Map.get(read, field)) ->
        {attrs, notes}

      # Quoted as the agent wrote it, cut short so a long value cannot fill the note.
      not settable?(field, value) ->
        json = Jason.encode!(value)
        shown = if String.length(json) > 60, do: String.slice(json, 0, 60) <> "…", else: json
        {attrs, ["Left the #{name}: #{shown} is not a value Rail takes" | notes]}

      Map.get(current, field) != Map.get(read, field) ->
        {attrs, ["Kept the #{name}, edited while the agent worked" | notes]}

      true ->
        {Map.put(attrs, field, value), [edited | notes]}
    end
  end

  # The result is JSON, so a priority arrives as a string and a cleared description as "" or null.
  defp same?(value, value), do: true
  defp same?(value, current) when is_binary(value) and is_atom(current), do: value == to_string(current)
  defp same?(_value, _current), do: false

  defp settable?(:title, value), do: is_binary(value) and String.trim(value) != ""
  defp settable?(:description, value), do: is_binary(value) or is_nil(value)
  defp settable?(:priority, value), do: value in Enum.map(Issue.priorities(), &to_string/1)
  defp settable?(:estimate, value), do: is_nil(value) or value in Issue.estimates()

  defp finish(%Issue{id: id}, outcome) do
    retrying =
      match?({:error, {:waiting_for_usage, _resets_at}}, outcome) or match?({:error, {:mcp_unreachable, _names}}, outcome)

    error =
      case outcome do
        {:ok, %ChatMessage{}} ->
          nil

        {:error, _reason} when retrying ->
          nil

        # The notice puts "Send a message to run it again." after the reason, so the reason ends its own sentence.
        {:error, reason} ->
          message = reason |> error_message() |> String.trim()
          if String.ends_with?(message, [".", "!", "?"]), do: message, else: message <> "."
      end

    Repo.update_all(from(i in Issue, where: i.id == ^id),
      set:
        [chat_started_at: nil, chat_token_hash: nil, chat_error: error] ++
          if(retrying, do: [], else: [chat_requested_at: nil])
    )

    Phoenix.PubSub.broadcast(Rail.PubSub, "issue_chats", {:issue_chat_changed, id})
  end

  defp error_message({:exit, code, output}) do
    case Tools.agent_failure_reason(output) do
      reason when is_binary(reason) -> "The agent exited with code #{code}: #{reason}"
      nil -> "The agent exited with code #{code}."
    end
  end

  defp error_message(:timeout), do: "It was still running after 30 minutes, so it was stopped."
  defp error_message(:dispatch_disabled), do: "Dispatch is switched off, so the agent did not run."

  defp error_message(:backend_signed_out),
    do: "The Triage role's backend is signed out. Sign it in under Settings → Backends."

  # The pass asks GitHub only for the token that fetches the default branch.
  defp error_message({:github_api_error, status, %{"message" => said}}) when is_binary(said),
    do: "Rail could not get a GitHub token to fetch the code. GitHub answered #{status}: #{said}"

  defp error_message({:github_api_error, status, _body}),
    do: "Rail could not get a GitHub token to fetch the code. GitHub answered #{status}"

  defp error_message(exception) when is_exception(exception), do: "The agent failed: #{Exception.message(exception)}"
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: "The agent failed: #{inspect(reason)}"

  defp scratch_path(%Issue{id: id, project_id: project_id}),
    do: Path.join([Rail.scratch_root(), project_id, "issue-chat", id])

  defp worktree_path(%Issue{id: id, project: project}), do: Path.join(project.clone_path, ".worktrees/issue-chat-#{id}")

  defp issue_file(%Issue{} = issue) do
    comments =
      Enum.map_join(issue.comments, "\n", fn %Comment{} = comment ->
        "### #{comment.author_name || "A teammate"} · #{DateTime.to_iso8601(comment.inserted_at)}\n\n#{comment.body}\n"
      end)

    """
    # #{issue.identifier} #{issue.title}

    Status: #{Issue.state_label(issue.state)} · Priority: #{Issue.priority_label(issue.priority) || "none"} · Estimate: #{issue.estimate || "none"}

    ## Description

    #{issue.description || "No description."}

    ## Comments

    #{if comments == "", do: "No comments.", else: comments}
    """
  end

  defp chat_file(%Issue{chat_messages: lines}) do
    Enum.map_join(lines, "\n", fn
      %ChatMessage{author: :person, user: user, text: text} -> "### #{person(user)}\n\n#{text}\n"
      %ChatMessage{author: :agent, text: text} -> "### You\n\n#{text}\n"
    end)
  end

  defp person(%{name: name}) when is_binary(name) and name != "", do: name
  defp person(%{login: login}) when is_binary(login), do: login
  defp person(_gone), do: "A teammate"

  defp brief(%Issue{} = issue, role) do
    dir = scratch_path(issue)
    file = Path.join(dir, "result.json")

    String.trim("""
    A teammate is asking you about #{issue.identifier}, an issue in #{issue.project.name} that nobody has started yet. Read #{Path.join(dir, "issue.md")}, the ticket as it stands with its comments, and #{Path.join(dir, "chat.md")}, your chat with the team so far. Your working directory is a checkout of the project's default branch.

    Do what the last message in chat.md asks, and answer it. Two asks are usual:

    - Whether the issue still applies. Find the behavior it describes in the code and follow it. Search the project's tickets with `search_issues` at least twice, in the ticket's words and then in the names you found in the code, and open a likely match with `get_issue`. Say what is already built and what is not, and name every ticket that covers it with its identifier, title and status.
    - Refining the ticket. Change only what the message asks you to change, and keep the rest as it reads.

    You are reading the code, not changing it: write no code and no files outside #{dir}, and never run a git command that writes. Use your MCP tools for evidence only; never post, create or change anything with them.
    #{rules(issue, role)}
    Write #{file} last, with a heredoc, the body and its closing JSON line at column zero:

    cat > #{file} <<'JSON'
    {
      "message": "what you tell the team",
      "ticket": {"title": "the new title", "description": "the new description, in markdown", "priority": "medium", "estimate": 2}
    }
    JSON

    - `message` is for the team, in two to six short sentences: what you found, and what you changed.
    - `ticket` holds only the fields you change, and is null when you change none. Rail applies it to the issue as soon as you finish.
    - A title states the behavior the product should have, as a sentence that is true once the issue is done. `priority` is `urgent`, `high`, `medium` or `low`. `estimate` is 1, 2, 3, 5, 8 or 13, or null.
    - Never change the issue's status, owner or anything else, and never offer to. A teammate closes an issue that no longer applies.
    """)
  end

  defp rules(%Issue{} = issue, role) do
    case Learnings.retrieve_learnings(role, ["#{issue.title}\n\n#{issue.description}"]) do
      [] ->
        ""

      rules ->
        lines =
          Enum.map_join(rules, "\n", fn %Learning{} = rule -> "- #{Learning.kind_label(rule.kind)}: #{rule.rule}" end)

        "\nWhat this project has learned, from people's corrections and decisions:\n\n#{lines}\n"
    end
  end
end
