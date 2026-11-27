defmodule Rail.Issues.Actions.WriteTestScenarios do
  @moduledoc """
  Runs an agent once on a merged ticket: it reads the ticket and the merge commit in a checkout of the default branch,
  and writes the scenarios the Testing page shows as "From the issue".
  """

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools

  @timeout to_timeout(minute: 30)
  @stale_after_minutes 45
  @most 12

  @doc """
  Writes the scenarios for `issue` from `merge_sha` and returns `:ok`, or `{:snooze, seconds}` while another pass holds
  it. Runs nothing once the stamp is cleared or past the claim window, so a retried, rescued or late job does nothing.
  """
  def write_test_scenarios(%Issue{id: id, project_id: project_id}, merge_sha) when is_binary(merge_sha) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    stale = DateTime.shift(now, minute: -@stale_after_minutes)
    cutoff = Issue.calculate_claim_cutoff(now)

    {claimed, _rows} =
      Repo.update_all(
        from(i in Issue,
          where:
            i.id == ^id and i.project_id == ^project_id and i.scenarios_requested_at > ^cutoff and
              (is_nil(i.scenarios_started_at) or i.scenarios_started_at < ^stale)
        ),
        set: [scenarios_started_at: now]
      )

    requested_at = Repo.one(from(i in Issue, where: i.id == ^id, select: i.scenarios_requested_at))

    cond do
      claimed == 1 -> Issue |> Repo.get!(id) |> Repo.preload(:project) |> run(merge_sha)
      # Another pass holds a live claim and may still finish; the two-hour bound covers it if it never does.
      is_struct(requested_at, DateTime) and DateTime.after?(requested_at, cutoff) -> {:snooze, 30}
      true -> :ok
    end
  end

  defp run(%Issue{} = issue, sha) do
    outcome =
      try do
        pass(issue, sha)
      rescue
        # A crash still reaches Sentry, but never leaves the ticket stuck on "Writing scenarios…".
        exception ->
          finish(issue, [])
          reraise exception, __STACKTRACE__
      after
        _removed = Git.remove_worktree(issue.project.clone_path, worktree_path(issue))
      end

    case outcome do
      {:ok, titles} -> finish(issue, titles)
      # Used-up accounts included: waiting for them would hold the ticket until they reset.
      {:error, _reason} -> finish(issue, [])
    end
  end

  defp pass(%Issue{} = issue, sha) do
    dir = scratch_path(issue)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "ticket.md"), "# #{issue.identifier} #{issue.title}\n\n#{issue.description}")

    with {:ok, role} <- Roles.get_role(project_id: issue.project_id, stage: :qa),
         {:ok, worktree} <- Git.checkout_detached_worktree(issue.project, worktree_path(issue)),
         {:ok, _output} <- Tools.run_agent(role, args(issue, role, worktree, sha, dir), cd: worktree, timeout: @timeout) do
      read_result(dir)
    end
  end

  defp args(issue, role, worktree, sha, dir) do
    Tools.build_args(
      prompt: Pipeline.build_prompt(context_snippet: brief(issue, sha, dir)),
      model: role.model,
      reasoning_effort: to_string(role.reasoning_effort || :medium),
      work_dir: worktree
    )
  end

  # The agent's file is untrusted: an empty, binary or malformed one is no result, and entries not text are dropped.
  defp read_result(dir) do
    with {:ok, body} <- File.read(Path.join(dir, "result.json")),
         {:ok, %{"scenarios" => titles}} when is_list(titles) <- Jason.decode(body) do
      titles =
        titles
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(@most)

      {:ok, titles}
    else
      _unreadable -> {:error, :no_result}
    end
  end

  # While the ticket is being written every testing action refuses, so the list is as the merge found it. Past the
  # two-hour wait the tester may have started, so a late result only clears the stamps.
  defp finish(%Issue{id: id, project_id: project_id}, titles) do
    {:ok, _written} =
      Repo.transaction(fn ->
        locked = Repo.one!(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE"))
        added = if Issue.writing_scenarios?(locked), do: Enum.map(titles, &TestingScenario.agent/1), else: []
        locked |> Issue.scenarios_written_changeset(locked.testing_scenarios ++ added) |> Repo.update!()
      end)

    Phoenix.PubSub.broadcast(Rail.PubSub, "testing", {:testing_changed, id})
    :ok
  end

  # Named by the claim, so a pass reclaimed after a dead one's 45 minutes never deletes a live pass's files.
  defp scratch_path(%Issue{id: id, project_id: project_id, scenarios_started_at: %DateTime{} = claimed}),
    do: Path.join([Rail.scratch_root(), project_id, "testing", "#{id}-#{DateTime.to_unix(claimed)}"])

  defp worktree_path(%Issue{id: id, project: project, scenarios_started_at: %DateTime{} = claimed}),
    do: Path.join(project.clone_path, ".worktrees/testing-#{id}-#{DateTime.to_unix(claimed)}")

  defp brief(%Issue{} = issue, sha, dir) do
    String.trim("""
    #{issue.identifier}, "#{issue.title}", was merged as commit #{sha}. Write the test scenarios a person follows on Rail's Testing page to check what shipped.

    The ticket is #{dir}/ticket.md. You are in a checkout of the default branch with that commit in it: read the change with `git show #{sha}`, and the code around it where you need to.

    Each scenario is one sentence a tester can follow in the running app: what to do, then what they should see. Cover every acceptance criterion, and the cases the ticket says must not happen. Leave out anything only the code or the tests can show. Write between 3 and #{@most}, in the order a tester would work through them.

    Write them to #{dir}/result.json as `{"scenarios": ["...", "..."]}`. Change nothing in the checkout.
    """)
  end
end
