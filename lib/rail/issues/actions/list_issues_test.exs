defmodule Rail.Issues.Actions.ListIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup %{project: project} do
    {:ok, other_project} =
      Projects.create_project(system_scope(), %{
        name: "List Issues Project Two",
        github_repo: "org/list-issues-two",
        github_installation_id: 5702,
        key: "LI2",
        default_branch: "main",
        clone_path: "/tmp/repos/list-issues-two"
      })

    %{project: project, other_project: other_project}
  end

  test "list_issues narrows to a cycle before the priority counts are taken", %{project: %Project{id: project_id}} do
    insert = fn external_id, cycle, priority ->
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project_id,
        external_id: external_id,
        identifier: external_id,
        title: external_id,
        state: :todo,
        priority: priority,
        cycle_external_id: cycle
      })
      |> Repo.insert!()
    end

    %Issue{id: high_id} = insert.("lin_lc1", "cyc_list", :high)
    %Issue{id: low_id} = insert.("lin_lc2", "cyc_list", :low)
    insert.("lin_lc3", "cyc_other", :high)
    insert.("lin_lc4", nil, :high)

    assert %{issues: [%Issue{id: ^high_id}], total: 1, priority_counts: %{high: 1, low: 1} = counts} =
             Issues.list_issues(project_id: project_id, cycle_id: "cyc_list", priority: :high)

    assert map_size(counts) == 2

    assert %{total: 2, issues: issues} = Issues.list_issues(project_id: project_id, cycle_id: "cyc_list")
    assert Enum.sort([high_id, low_id]) == issues |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "list_issues takes a list of cycles, as it does of projects", %{
    project: %Project{id: project_id},
    other_project: %Project{id: other_id}
  } do
    insert = fn external_id, project_id, cycle ->
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project_id,
        external_id: external_id,
        identifier: external_id,
        title: external_id,
        state: :todo,
        cycle_external_id: cycle
      })
      |> Repo.insert!()
    end

    %Issue{id: here_id} = insert.("lin_lcl1", project_id, "cyc_here")
    %Issue{id: there_id} = insert.("lin_lcl2", other_id, "cyc_there")
    insert.("lin_lcl3", project_id, "cyc_elsewhere")
    insert.("lin_lcl4", other_id, nil)

    assert %{total: 2, issues: issues} =
             Issues.list_issues(project_id: [project_id, other_id], cycle_id: ["cyc_here", "cyc_there"])

    assert Enum.sort([here_id, there_id]) == issues |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "list_issues filters by project, state and whether finished issues show", %{
    project: %Project{id: project_id},
    other_project: other_project
  } do
    %Issue{id: triage_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project_id,
        external_id: "lin_l1",
        identifier: "LI1-1",
        title: "Triage",
        state: :triage
      })
      |> Repo.insert!()

    %Issue{id: done_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project_id,
        external_id: "lin_l2",
        identifier: "LI1-2",
        title: "Done",
        state: :done
      })
      |> Repo.insert!()

    %Issue{}
    |> Issue.changeset(%{
      project_id: other_project.id,
      external_id: "lin_l3",
      identifier: "LI2-1",
      title: "Elsewhere",
      state: :in_progress
    })
    |> Repo.insert!()

    %Issue{id: duplicate_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project_id,
        external_id: "lin_l4",
        identifier: "LI1-3",
        title: "Duplicate",
        priority: :urgent,
        state: :duplicate
      })
      |> Repo.insert!()

    # Pinned so the Duplicate issue's urgent priority is not counted.
    only_medium = %{medium: 1}

    assert %{issues: [%Issue{id: ^triage_id}], total: 1, priority_counts: ^only_medium} =
             Issues.list_issues(project_id: project_id)

    assert %{
             issues: [%Issue{id: ^duplicate_id}, %Issue{id: ^done_id}, %Issue{id: ^triage_id}],
             total: 3,
             priority_counts: %{urgent: 1, medium: 2}
           } = Issues.list_issues(project_id: project_id, show_finished: true)

    assert %{issues: [%Issue{id: ^triage_id}]} = Issues.list_issues(project_id: project_id, state: :triage)

    assert %{issues: [%Issue{id: ^triage_id, project: %Project{id: ^project_id}}]} =
             Issues.list_issues(project_id: project_id, preload: [:project])

    assert %{total: 4} = Issues.list_issues(show_finished: true)
    assert %{total: 2} = Issues.list_issues()

    assert %{issues: [%Issue{id: ^triage_id}], total: 1} = Issues.list_issues(project_id: [project_id])
    assert %{total: 2} = Issues.list_issues(project_id: [project_id, other_project.id])
    assert %{issues: [], total: 0, priority_counts: %{}} = Issues.list_issues(project_id: [], show_finished: true)
  end

  test "list_issues searches titles and identifiers, taking the search literally", %{project: project} do
    %Issue{id: login_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_s1",
        identifier: "LI1-10",
        title: "Fix Login redirect",
        state: :triage
      })
      |> Repo.insert!()

    %Issue{id: percent_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_s2",
        identifier: "LI1-20",
        title: "Show 100% width",
        state: :triage
      })
      |> Repo.insert!()

    %Issue{}
    |> Issue.changeset(%{
      project_id: project.id,
      external_id: "lin_s3",
      identifier: "LI1-30",
      title: "Other",
      state: :triage
    })
    |> Repo.insert!()

    assert %{issues: [%Issue{id: ^login_id}], total: 1} = Issues.list_issues(search: "login")
    assert %{issues: [%Issue{id: ^percent_id}]} = Issues.list_issues(search: "li1-20")
    assert %{issues: [%Issue{id: ^percent_id}]} = Issues.list_issues(search: "100%")
    assert %{issues: [], total: 0} = Issues.list_issues(search: "1_0")
    assert %{total: 3} = Issues.list_issues(search: "   ")
  end

  test "list_issues puts the issue a search names by its identifier first, ahead of newer ones it prefixes", %{
    project: project
  } do
    %Issue{id: exact_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_exact",
        identifier: "LI1-2",
        title: "Named exactly",
        state: :triage
      })
      |> Repo.insert!()

    for n <- 20..29 do
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_prefixed_#{n}",
        identifier: "LI1-#{n}",
        title: "Prefixed #{n}",
        state: :triage
      })
      |> Repo.insert!()
    end

    assert %{issues: [%Issue{id: ^exact_id} | _newer], total: 11} = Issues.list_issues(search: " li1-2 ", limit: 8)
    assert %{issues: [%Issue{identifier: "LI1-29"} | _older]} = Issues.list_issues(search: "Prefixed", limit: 8)
  end

  test "list_issues pages through issues, most recently updated first, and counts past the page", %{project: project} do
    issues =
      for {priority, n} <- Enum.with_index([:medium, :low, :high, :high, :urgent]) do
        %Issue{}
        |> Issue.changeset(%{
          project_id: project.id,
          external_id: "lin_p#{n}",
          identifier: "LI1-#{100 + n}",
          title: "Paged #{n}",
          priority: priority,
          state: :backlog
        })
        |> Repo.insert!()
      end

    [fifth, fourth, third, second, first] = Enum.map(issues, & &1.id)

    assert %{
             issues: [%Issue{id: ^first}, %Issue{id: ^second}],
             total: 5,
             priority_counts: %{urgent: 1, high: 2, low: 1, medium: 1}
           } = Issues.list_issues(limit: 2)

    assert %{issues: [%Issue{id: ^third}, %Issue{id: ^fourth}], total: 5} = Issues.list_issues(limit: 2, offset: 2)
    assert %{issues: [%Issue{id: ^fifth}]} = Issues.list_issues(limit: 2, offset: 4)

    # Picking a priority narrows the list and its total, but every chip still counts.
    assert %{
             issues: [%Issue{id: ^second}, %Issue{id: ^third}],
             total: 2,
             priority_counts: %{urgent: 1, high: 2, low: 1, medium: 1}
           } = Issues.list_issues(priority: :high)

    # Leaving issues out happens before the limit, so the page still fills.
    assert %{issues: [%Issue{id: ^third}, %Issue{id: ^fourth}]} =
             Issues.list_issues(limit: 2, exclude_ids: [first, second])

    # Updating the oldest issue brings it to the top.
    issues |> List.first() |> Issue.changeset(%{title: "Touched"}) |> Repo.update!()
    assert %{issues: [%Issue{id: ^fifth}]} = Issues.list_issues(limit: 1)
  end

  test "list_issues preloads the issue's task", %{project: project} do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_t1",
        identifier: "LI1-40",
        title: "Tasked",
        state: :backlog
      })
      |> Repo.insert!()

    {:ok, %Task{id: task_id}} = Pipeline.create_task(%{issue | project: project}, :plan)

    assert %{issues: [%Issue{task: %Task{id: ^task_id, runs: []}}]} =
             Issues.list_issues(preload: [task: :runs])
  end

  test "list_issues narrows to the issues completed since a moment", %{project: project} do
    completed = fn external_id, completed_at ->
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: external_id,
        identifier: "LI1-#{external_id}",
        title: external_id,
        state: :done,
        completed_at: completed_at
      })
      |> Repo.insert!()
    end

    %Issue{id: recent_id} = completed.("recent", ~U[2026-09-10 00:00:00Z])
    completed.("long_ago", ~U[2026-01-01 00:00:00Z])
    completed.("open", nil)

    assert %{issues: [%Issue{id: ^recent_id}]} =
             Issues.list_issues(show_finished: true, completed_after: ~U[2026-09-01 00:00:00Z])
  end

  test "list_issues leaves out an archived issue no task holds, unless asked for every one", %{project: project} do
    issue = fn external_id, archived_at ->
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: external_id,
        identifier: "LI1-#{external_id}",
        title: external_id,
        state: :done,
        archived_at: archived_at
      })
      |> Repo.insert!()
      |> Repo.preload(:project)
    end

    %Issue{id: live_id} = issue.("live", nil)
    %Issue{id: untasked_id} = issue.("archived_untasked", ~U[2026-10-06 00:00:00Z])
    %Issue{id: tasked_id} = tasked = issue.("archived_tasked", ~U[2026-10-06 00:00:00Z])
    {:ok, _task} = Pipeline.create_task(tasked, :merged)

    ids = fn opts -> opts |> Issues.list_issues() |> Map.fetch!(:issues) |> Enum.map(& &1.id) |> Enum.sort() end

    assert ids.(show_finished: true) == Enum.sort([live_id, tasked_id])
    assert ids.(show_finished: true, archived: true) == Enum.sort([live_id, untasked_id, tasked_id])
  end

  test "list_issues narrows to the issues a user owns", %{project: project} do
    {:ok, %{id: owner_id}} =
      Rail.Users.register_oauth_user(%{github_id: "gh_list_owner", login: "list_owner", email: "list_owner@example.com"})

    %Issue{id: mine_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_o1",
        identifier: "LI1-50",
        title: "Mine",
        state: :backlog,
        owner_user_id: owner_id
      })
      |> Repo.insert!()

    %Issue{}
    |> Issue.changeset(%{
      project_id: project.id,
      external_id: "lin_o2",
      identifier: "LI1-51",
      title: "Not mine",
      state: :backlog
    })
    |> Repo.insert!()

    assert %{issues: [%Issue{id: ^mine_id}], total: 1} = Issues.list_issues(owner_user_id: owner_id)
    assert %{total: 2} = Issues.list_issues()
  end

  describe "an ended Rail cycle" do
    setup do
      key = "LIC#{System.unique_integer([:positive])}"

      {:ok, local} =
        Projects.create_project(system_scope(), %{
          name: "Listed cycles",
          github_repo: "example/#{key}",
          github_installation_id: 1,
          tracker: :local,
          key: key,
          default_branch: "main",
          clone_path: "/tmp/#{key}"
        })

      # Cycle 1 runs Nov 10 to 23 and closes holding `rolled` In Progress and `kept` Done.
      :ok = Issues.close_cycle_day(~D[2026-11-10])
      stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
      {:ok, %{cycles: [first, second | _later]}} = Issues.get_cycles(local)
      {:ok, rolled} = Issues.create_issue(system_scope(), local, %{title: "Rolls over", estimate: 3})
      {:ok, kept} = Issues.create_issue(system_scope(), local, %{title: "Stays", estimate: 2})
      {:ok, rolled} = Issues.set_issue_cycle(system_scope(), rolled, first.id)
      {:ok, kept} = Issues.set_issue_cycle(system_scope(), kept, first.id)
      in_progress = %{id: "in_progress", name: "In Progress", state: :in_progress}
      {:ok, rolled} = Issues.set_issue_status(system_scope(), rolled, in_progress)
      {:ok, kept} = Issues.set_issue_status(system_scope(), kept, %{id: "done", name: "Done", state: :done})
      :ok = Issues.close_cycle_day(~D[2026-11-24])

      # In Cycle 2, `rolled` is finished and `kept` reopened.
      stub(Date, :utc_today, fn -> ~D[2026-11-25] end)
      {:ok, _done} = Issues.set_issue_status(system_scope(), rolled, %{id: "done", name: "Done", state: :done})
      {:ok, _reopened} = Issues.set_issue_status(system_scope(), kept, %{id: "todo", name: "Todo", state: :todo})

      %{local: local, first: first, second: second, rolled: rolled, kept: kept}
    end

    test "filters and counts each issue it held by the state it closed in, and returns it as it is now", %{
      local: local,
      first: first,
      second: second,
      rolled: %{id: rolled_id},
      kept: %{id: kept_id}
    } do
      assert %{
               issues: [%Issue{id: ^rolled_id, state: :done, state_name: "Done", cycle_state: :in_progress}],
               total: 1
             } = Issues.list_issues(project_id: local.id, cycle_id: first.id)

      assert %{issues: issues, total: 2} =
               Issues.list_issues(project_id: local.id, cycle_id: first.id, show_finished: true, preload: [:task])

      assert %{
               ^rolled_id => {:done, :in_progress, nil},
               ^kept_id => {:todo, :done, nil}
             } = Map.new(issues, &{&1.id, {&1.state, &1.cycle_state, &1.task}})

      assert %{issues: [%Issue{id: ^rolled_id, state: :done, cycle_state: :done, cycle_state_name: "Done"}]} =
               Issues.list_issues(project_id: local.id, cycle_id: second.id, show_finished: true)
    end
  end
end
