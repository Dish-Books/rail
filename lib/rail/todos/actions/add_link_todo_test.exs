defmodule Rail.Todos.Actions.AddLinkTodoTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  setup %{project: project} do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_link_#{n}", login: "link_#{n}", email: "link_#{n}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    scope = Scope.for_user(user)

    {:ok, hidden} =
      Projects.create_project(system_scope(), %{
        name: "Hidden #{n}",
        github_repo: "org/hidden-#{n}",
        github_installation_id: n,
        key: "HID#{n}",
        default_branch: "main",
        clone_path: "/tmp/repos/hidden-#{n}",
        active: true
      })

    %{channel: channel} = connect_slack_channel(project)
    {:ok, anchor} = Todos.create_todo(scope, %{"body" => "Anchor"}, :last)
    Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{user.id}")
    %{user: user, scope: scope, hidden: hidden, channel: channel, anchor: anchor}
  end

  test "names each Rail record by what it is and lands it in front of the row named",
       %{user: %{id: user_id}, scope: scope, project: project, channel: channel, anchor: anchor} do
    task = learnings_task(project, "RAIL-41")

    thread =
      Repo.insert!(%Thread{
        project_id: project.id,
        slack_channel_id: channel.id,
        external_id: "1.1",
        title: "Deploy failed"
      })

    rule = learning(project, %{rule: "Never connect\nto production", kind: :convention})
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)

    proposal =
      Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id, title: "Use scopes"})

    for {url, text} <- [
          {"/tasks/#{task.id}", "dragged"},
          {"/issues/#{task.issue.id}", "dragged"},
          {"/testing/#{task.issue.identifier}", "dragged"},
          {"/triage/#{thread.id}", "dragged"},
          {"/learnings/#{rule.id}", "dragged"},
          {"/learnings/proposals/#{proposal.id}", "dragged"}
        ] do
      assert {:ok, %Todo{url: ^url}} = Todos.add_link_todo(scope, url, text, anchor.id)
      assert_received {:todos_changed, ^user_id}
    end

    assert [
             "RAIL-41 Work on RAIL-41",
             "RAIL-41 Work on RAIL-41",
             "RAIL-41 Work on RAIL-41",
             "Triage: Deploy failed",
             "Learning: Never connect to production",
             "Learning proposal: Use scopes",
             "Anchor"
           ] = Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.body)
  end

  test "names a task link by the finding in its address, or by the task when there is no such finding",
       %{scope: scope, project: project} do
    task = learnings_task(project, "RAIL-38", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, _finding} =
      Pipeline.save_finding(task, %{
        key: "ruling-scrolls",
        title: "Ruling Fix scrolls the list",
        severity: :major,
        kind: :code,
        raised_by: :code_reviewer,
        problem: "It scrolls.",
        file: "lib/a.ex",
        line: 3,
        fix: "Keep it.",
        why: "It scrolls.",
        rule: "Lists keep their place.",
        recommendation: :fix,
        places: [%{file: "lib/a.ex", line: 3}],
        evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
      })

    assert {:ok, %Todo{body: "RAIL-38 finding: Ruling Fix scrolls the list"}} =
             Todos.add_link_todo(scope, "/tasks/#{task.id}?item=findings&finding=ruling-scrolls", "dragged", :last)

    assert {:ok, %Todo{body: "RAIL-38 Work on RAIL-38"}} =
             Todos.add_link_todo(scope, "/tasks/#{task.id}?item=findings&finding=no-such-finding", "dragged", :last)

    assert {:ok, %Todo{body: "RAIL-38 Work on RAIL-38"}} =
             Todos.add_link_todo(scope, "/tasks/#{task.id}/screens/home", "dragged", :last)
  end

  test "names a split's page by the child in its address", %{scope: scope, project: project} do
    parent = learnings_task(project, "RAIL-50")
    child = learnings_task(project, "RAIL-51")
    child |> Ecto.Changeset.change(parent_task_id: parent.id, split_position: 1) |> Repo.update!()

    assert {:ok, %Todo{body: "RAIL-51 Work on RAIL-51"}} =
             Todos.add_link_todo(scope, "/tasks/#{parent.id}?child=RAIL-51", "dragged", :last)

    assert {:ok, %Todo{body: "RAIL-50 Work on RAIL-50"}} =
             Todos.add_link_todo(scope, "/tasks/#{parent.id}?child=RAIL-99", "dragged", :last)
  end

  test "keeps the dragged text for an untitled thread or proposal",
       %{scope: scope, project: project, channel: channel} do
    thread = Repo.insert!(%Thread{project_id: project.id, slack_channel_id: channel.id, external_id: "2.2"})
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})

    assert {:ok, %Todo{body: "A thread"}} = Todos.add_link_todo(scope, "/triage/#{thread.id}", "A thread", :last)

    assert {:ok, %Todo{body: "A proposal"}} =
             Todos.add_link_todo(scope, "/learnings/proposals/#{proposal.id}", "A proposal", :last)
  end

  test "names Rail's own pages, and keeps the text for a path it does not know", %{scope: scope} do
    assert {:ok, %Todo{body: "Sandboxes"}} = Todos.add_link_todo(scope, "/sandboxes", "dragged", :last)
    assert {:ok, %Todo{body: "Settings"}} = Todos.add_link_todo(scope, "/settings/workflows", "dragged", :last)
    assert {:ok, %Todo{body: "Overview"}} = Todos.add_link_todo(scope, "/", "dragged", :last)
    assert {:ok, %Todo{body: "Somewhere"}} = Todos.add_link_todo(scope, "/nowhere/at/all", "Somewhere", :last)
    assert {:ok, %Todo{body: "A gone task"}} = Todos.add_link_todo(scope, "/tasks/tsk_gone", "A gone task", :last)
  end

  test "keeps the dragged text for records in a project the person cannot see",
       %{scope: scope, hidden: hidden, channel: channel} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: hidden.id,
        identifier: "HID-1",
        title: "Secret",
        state: :todo
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, task} = Pipeline.create_task(issue, :plan)

    thread =
      Repo.insert!(%Thread{project_id: hidden.id, slack_channel_id: channel.id, external_id: "3.3", title: "Secret"})

    rule = learning(hidden, %{rule: "Secret", kind: :convention})
    draft = learning(hidden, %{rule: "Draft", kind: :convention}, status: :proposed)

    proposal =
      Repo.insert!(%LearningProposal{project_id: hidden.id, action: :add, learning_id: draft.id, title: "Secret"})

    for url <- [
          "/tasks/#{task.id}",
          "/issues/#{issue.id}",
          "/triage/#{thread.id}",
          "/learnings/#{rule.id}",
          "/learnings/proposals/#{proposal.id}"
        ] do
      assert {:ok, %Todo{body: "What I dragged"}} = Todos.add_link_todo(scope, url, "What I dragged", :last)
    end
  end

  test "names a GitHub pull request by the task that opened it", %{scope: scope, project: project, hidden: hidden} do
    task = learnings_task(project, "RAIL-177")
    {:ok, _task} = Pipeline.update_task(task, %{pr_url: "https://github.com/acme/rail/pull/268"})

    hidden_issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: hidden.id,
        identifier: "HID-2",
        title: "Secret",
        state: :todo
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, hidden_task} = Pipeline.create_task(hidden_issue, :plan)
    {:ok, _hidden_task} = Pipeline.update_task(hidden_task, %{pr_url: "https://github.com/acme/secret/pull/7"})

    assert {:ok, %Todo{body: "RAIL-177 Work on RAIL-177 (pull request #268)"}} =
             Todos.add_link_todo(scope, "https://github.com/acme/rail/pull/268/files", "Workflows", :last)

    assert {:ok, %Todo{body: "Something else"}} =
             Todos.add_link_todo(scope, "https://github.com/acme/rail/pull/999", "Something else", :last)

    assert {:ok, %Todo{body: "A secret"}} =
             Todos.add_link_todo(scope, "https://github.com/acme/secret/pull/7", "A secret", :last)

    assert {:ok, %Todo{body: "Repo"}} = Todos.add_link_todo(scope, "https://github.com/acme/rail", "Repo", :last)
  end

  test "names an outside link with blank text by its address, and cuts a long name to 500 characters",
       %{scope: scope} do
    assert {:ok, %Todo{body: "https://example.com/a", url: "https://example.com/a"}} =
             Todos.add_link_todo(scope, "https://example.com/a", "  \n ", :last)

    assert {:ok, %Todo{body: body}} =
             Todos.add_link_todo(scope, "https://example.com/b", String.duplicate("x", 600), :last)

    assert String.length(body) == 500
  end

  test "refuses an address that is not a Rail path or an http(s) link, and a scope with no user",
       %{user: %{id: user_id}, scope: scope} do
    before = Repo.all(from t in Todo, where: t.user_id == ^user_id, select: {t.id, t.position, t.updated_at})

    assert {:error, %Ecto.Changeset{}} = Todos.add_link_todo(scope, "javascript:alert(1)", "Click", :last)
    assert ^before = Repo.all(from t in Todo, where: t.user_id == ^user_id, select: {t.id, t.position, t.updated_at})
    refute_received {:todos_changed, _user_id}

    assert {:error, :not_authenticated} = Todos.add_link_todo(system_scope(), "/sandboxes", "Sandboxes", :last)
  end
end
