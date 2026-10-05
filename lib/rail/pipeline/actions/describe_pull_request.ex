defmodule Rail.Pipeline.Actions.DescribePullRequest do
  @moduledoc """
  Writes a task's pull request description over Rail's own placeholder, with an
  agent of its own on the Engineer role's backend and model but no role prompt.

  The body is read again once the agent is done, because a person can rewrite it
  in the minutes the agent runs, and only a body still the placeholder is replaced.
  """

  import Rail.Pipeline.Utils.DraftBody
  import Rail.Pipeline.Utils.SplitDemoSection

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Mcp
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @timeout to_timeout(minute: 15)
  @sections ["## Summary", "## Evidence", "## Merge Danger"]

  @doc """
  Describes `task`'s pull request. Returns `:ok` when it was written or the body
  is not Rail's to replace, or `{:error, reason}`.
  """
  def describe_pull_request(%Task{pr_number: number} = task) when is_integer(number) do
    %Task{project: %Project{} = project, issue: %Issue{} = issue} = task = Repo.preload(task, [:project, :issue])

    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, pull_request} <- GitHub.get_pull_request(token, project.github_repo, number),
         {:ok, _demo} <- placeholder(pull_request, issue),
         {:ok, written} <- write(task, project, issue),
         {:ok, pull_request} <- GitHub.get_pull_request(token, project.github_repo, number),
         {:ok, demo} <- placeholder(pull_request, issue),
         body = [issue.url, written, demo] |> Enum.filter(&is_binary/1) |> Enum.join("\n\n"),
         {:ok, _updated} <- GitHub.update_pull_request(token, project.github_repo, number, %{body: body}) do
      :ok
    else
      :not_placeholder -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The demo section is Rail's too, and a body that came back with CRLFs is still the placeholder.
  defp placeholder(%{} = pull_request, %Issue{} = issue) do
    {kept, demo} = (pull_request["body"] || "") |> String.replace("\r\n", "\n") |> split_demo_section()
    if String.trim(kept) == draft_body(issue), do: {:ok, demo}, else: :not_placeholder
  end

  defp write(%Task{} = task, %Project{} = project, %Issue{} = issue) do
    {:ok, %Role{} = role} = Roles.get_role(project_id: task.project_id, stage: :engineer)
    file = Path.join([task.scratch_path, "pr", "#{issue.identifier}.md"])
    File.mkdir_p!(Path.dirname(file))
    # A file an earlier attempt left is not this agent's answer.
    File.rm(file)

    prompt =
      Pipeline.build_prompt(
        backend: role.backend,
        context_snippet: brief(task, project, issue, role, file),
        ticket: issue.description
      )

    args =
      Tools.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: to_string(role.reasoning_effort || :high),
        work_dir: task.worktree_path
      )

    # Rail's MCP server is always configured, and a token it never stored gives this agent none of its tools.
    {mcp_token, _hash} = Mcp.issue_run_token()
    run_opts = [cd: task.worktree_path, timeout: @timeout, env: %{"RAIL_MCP_TOKEN" => mcp_token}]

    with {:ok, _output} <- Tools.run_agent(role.backend, args, run_opts) do
      written =
        case File.read(file) do
          {:ok, text} -> String.trim(text)
          {:error, _missing} -> ""
        end

      lines = written |> String.split(~r/\R/) |> Enum.map(&String.trim_trailing/1)

      if String.valid?(written) and Enum.all?(@sections, &(&1 in lines)),
        do: {:ok, written},
        else: {:error, :incomplete_description}
    end
  end

  defp brief(%Task{} = task, %Project{} = project, %Issue{} = issue, %Role{} = role, file) do
    base = "origin/#{project.default_branch}"

    plan =
      case Pipeline.get_implementation_plan(task) do
        {:ok, %ImplementationPlan{content: content}} -> "The approved implementation plan:\n\n#{String.trim(content)}\n"
        {:error, :not_found} -> "There is no approved implementation plan for this change.\n"
      end

    ci =
      with %Run{} = run <- Repo.get_by(Run, task_id: task.id, role_id: role.id),
           %{os_process: %OsProcess{stream_path: stream_path}} <- Pipeline.get_ci_status(run) do
        "CI's output on this branch is in #{stream_path}. Read it for the Evidence."
      else
        _no_ci -> "This project has no CI log to read, so the Evidence comes from the tests the branch adds or changes."
      end

    String.trim("""
    Write the pull request description for #{issue.identifier} #{issue.title}, the change on the branch checked out in your working directory. A reviewer reads it on GitHub before reading any code, so it has to show what changed and how risky merging it is.

    You are describing the change, not changing it: write no code, no tests and no files outside #{Path.dirname(file)}, and never run a git command that writes. Do not run the test suite. Read the change with `git diff #{base}...HEAD` and `git log #{base}..HEAD`.

    #{ci}

    Use the domain language in #{Path.join(task.worktree_path, "CONTEXT.md")} when it exists, and the code's own names when it does not. Follow any pull request conventions in the project's CLAUDE.md or docs/.

    #{plan}
    Writing #{file} is how you report, and it is the last thing you do. Write it with a heredoc, the body and its closing MD line at column zero:

    cat > #{file} <<'MD'
    ## Summary

    The smallest visual that explains the change, and at most two sentences.

    ## Evidence

    **Before:** ...

    **After:** ...

    ## Merge Danger

    **Door:** ...

    **Blast Radius:** ...
    MD

    - `## Summary` is one visual: a mermaid diagram, a diff sketch, a call tree or a file tree, whichever is smallest and still explains the change. At most two sentences go with it.
    - `## Evidence` is a **Before** and an **After**, taken from CI's output or from the tests the branch adds or changes. Quote what they show; do not describe what you expect them to show.
    - `## Merge Danger` names the **Door**, one-way or two-way and why: a one-way door is a change that cannot simply be reverted, such as a migration that drops data or a message already sent. **Blast Radius** is who and what breaks if the change is wrong.
    - Keep all three headings, exactly as written. Leave out the ticket link, any demo, open questions and assumptions: Rail adds what belongs on the pull request itself.
    """)
  end
end
