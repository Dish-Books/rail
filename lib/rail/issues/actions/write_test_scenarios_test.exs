defmodule Rail.Issues.Actions.WriteTestScenariosTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects
  alias Rail.Tools

  setup %{project: project} do
    test = self()
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)

    stub(Git, :remove_worktree, fn _clone_path, worktree_path ->
      send(test, {:removed, worktree_path})
      :ok
    end)

    {:ok, issue} =
      Issues.create_issue(system_scope(), project, %{title: "Export keeps icons", description: "Six icons fit."})

    {:ok, done} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    # A scenario the tester added before the ticket was reopened and merged again.
    {:ok, earlier} = Issues.add_testing_scenario(system_scope(), done, "Kept from before")
    {:ok, requested} = Issues.request_test_scenarios(earlier, "3c9a1f0e2b")
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    # The pass's folder is named by its claim, which it stamps as it starts.
    dir = fn %Issue{id: id, project_id: project_id} ->
      %Issue{scenarios_started_at: claimed} = Repo.get!(Issue, id)
      Path.join([Rail.scratch_root(), project_id, "testing", "#{id}-#{DateTime.to_unix(claimed)}"])
    end

    %{issue: requested, dir: dir}
  end

  test "the agent's scenarios go after those already there, labeled as its own, and both stamps are cleared", %{
    issue: %Issue{id: issue_id} = issue,
    dir: dir
  } do
    test = self()

    expect(Tools, :run_agent, fn %{stage: :qa}, _argv, opts ->
      folder = dir.(issue)
      send(test, {:ran, folder, opts[:cd], File.read!(Path.join(folder, "ticket.md"))})

      File.write!(
        Path.join(folder, "result.json"),
        Jason.encode!(%{"scenarios" => [" Open the export ", "", 7, "Six icons fit on the row"]})
      )

      {:ok, ""}
    end)

    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")

    assert_received {:ran, folder, worktree, "# " <> ticket}
    assert ticket =~ "Export keeps icons\n\nSix icons fit."
    assert worktree =~ ~r{/\.worktrees/testing-#{issue_id}-\d+\z}
    assert folder =~ ~r{/testing/#{issue_id}-\d+\z}
    assert_received {:removed, ^worktree}

    assert %Issue{
             testing_state: :testing,
             scenarios_requested_at: nil,
             scenarios_started_at: nil,
             testing_scenarios: [
               %TestingScenario{title: "Kept from before", source: :tester},
               %TestingScenario{title: "Open the export", source: :agent, result: nil},
               %TestingScenario{title: "Six icons fit on the row", source: :agent}
             ]
           } = Repo.get!(Issue, issue_id)

    assert_received {:testing_changed, ^issue_id}
  end

  test "the agent's list is cut to twelve", %{issue: %Issue{id: issue_id} = issue, dir: dir} do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      titles = for n <- 1..15, do: "Scenario #{n}"
      File.write!(Path.join(dir.(issue), "result.json"), Jason.encode!(%{"scenarios" => titles}))
      {:ok, ""}
    end)

    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")
    assert %Issue{testing_scenarios: [_kept | written]} = Repo.get!(Issue, issue_id)
    assert length(written) == 12
  end

  test "a job whose stamp is already cleared runs no agent", %{issue: %Issue{id: issue_id} = issue} do
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [scenarios_requested_at: nil])
    reject(&Tools.run_agent/3)

    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")
  end

  test "a job meeting a live claim snoozes and leaves both stamps", %{issue: %Issue{id: issue_id} = issue} do
    claimed = DateTime.utc_now() |> DateTime.shift(minute: -10) |> DateTime.truncate(:second)
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [scenarios_started_at: claimed])
    reject(&Tools.run_agent/3)

    assert {:snooze, 30} = Issues.write_test_scenarios(issue, "3c9a1f0e2b")
    assert %Issue{scenarios_requested_at: %DateTime{}, scenarios_started_at: ^claimed} = Repo.get!(Issue, issue_id)
  end

  test "a claim older than 45 minutes is a dead one, and the pass claims the ticket again", %{
    issue: %Issue{id: issue_id} = issue,
    dir: dir
  } do
    dead = DateTime.utc_now() |> DateTime.shift(minute: -46) |> DateTime.truncate(:second)
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [scenarios_started_at: dead])

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(Path.join(dir.(issue), "result.json"), ~s({"scenarios": ["Open it"]}))
      {:ok, ""}
    end)

    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")
    assert %Issue{scenarios_started_at: nil, testing_scenarios: [_kept, %{title: "Open it"}]} = Repo.get!(Issue, issue_id)
  end

  test "a job past the claim window returns without an agent and leaves the wait to its bound", %{
    issue: %Issue{id: issue_id} = issue
  } do
    late = DateTime.utc_now() |> DateTime.shift(minute: -61) |> DateTime.truncate(:second)
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [scenarios_requested_at: late])
    reject(&Tools.run_agent/3)

    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")
    assert %Issue{scenarios_requested_at: ^late} = Repo.get!(Issue, issue_id)
  end

  test "an agent that crashes clears both stamps, adds nothing and still reaches Sentry", %{
    issue: %Issue{id: issue_id} = issue
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts -> raise "the agent's process died" end)

    assert_raise RuntimeError, "the agent's process died", fn -> Issues.write_test_scenarios(issue, "3c9a1f0e2b") end

    assert %Issue{scenarios_requested_at: nil, scenarios_started_at: nil, testing_scenarios: [_kept]} =
             Repo.get!(Issue, issue_id)

    assert_received {:removed, _worktree}
    assert_received {:testing_changed, ^issue_id}
  end

  test "an agent that fails, writes nothing, or writes what Rail cannot read clears both stamps and adds nothing", %{
    issue: %Issue{id: issue_id} = issue,
    dir: dir
  } do
    results = [
      {:error, {:waiting_for_usage, DateTime.utc_now()}},
      {:error, {:exit, 1, "boom"}},
      :no_file,
      "",
      <<0xFF, 0xFE, 0x00>>,
      ~s({"scenarios": "one"}),
      ~s(["not", "an", "object"])
    ]

    for result <- results do
      {:ok, _requested} = Issues.request_test_scenarios(issue, "3c9a1f0e2b")

      expect(Tools, :run_agent, fn _role, _argv, _opts ->
        case result do
          {:error, _reason} = failed -> failed
          :no_file -> {:ok, ""}
          body -> {File.write!(Path.join(dir.(issue), "result.json"), body), ""}
        end
      end)

      assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")

      assert %Issue{scenarios_requested_at: nil, scenarios_started_at: nil, testing_scenarios: [_kept]} =
               Repo.get!(Issue, issue_id)
    end
  end

  test "a checkout that fails, or a project with no QA role, ends the wait with no scenarios", %{
    issue: %Issue{id: issue_id} = issue
  } do
    expect(Git, :checkout_detached_worktree, fn _project, _path -> {:error, "fatal: no origin"} end)
    reject(&Tools.run_agent/3)

    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")
    assert %Issue{scenarios_requested_at: nil, testing_scenarios: [_kept]} = Repo.get!(Issue, issue_id)

    key = "Wts#{System.unique_integer([:positive])}"

    {:ok, bare} =
      Projects.create_project(system_scope(), %{
        name: "No roles",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, other} = Issues.create_issue(system_scope(), bare, %{title: "No QA"})
    {:ok, other} = Issues.request_test_scenarios(other, "3c9a1f0e2b")

    assert :ok = Issues.write_test_scenarios(other, "3c9a1f0e2b")
    assert %Issue{scenarios_requested_at: nil, testing_scenarios: []} = Repo.get!(Issue, other.id)
  end

  test "a result that arrives after the two-hour wait adds nothing and only clears the stamps", %{
    issue: %Issue{id: issue_id} = issue,
    dir: dir
  } do
    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      File.write!(Path.join(dir.(issue), "result.json"), ~s({"scenarios": ["Too late"]}))
      expired = DateTime.utc_now() |> DateTime.shift(minute: -121) |> DateTime.truncate(:second)
      Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [scenarios_requested_at: expired])
      {:ok, ""}
    end)

    assert :ok = Issues.write_test_scenarios(issue, "3c9a1f0e2b")

    assert %Issue{
             scenarios_requested_at: nil,
             scenarios_started_at: nil,
             testing_scenarios: [%{title: "Kept from before"}]
           } =
             Repo.get!(Issue, issue_id)
  end
end
