defmodule Rail.Pipeline.Actions.ApplyPlanRevisionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: extends the module.

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  @design "## Design: Table\n\nDense rows.\n\n![Table](https://uploads.linear.app/assets/table.png)"

  setup %{project: project} do
    roles =
      Map.new([:plan, :engineer], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_revision_1", "identifier" => "REV-1", "title" => "Revision"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "The raw ask."})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, _ticket} =
      Pipeline.save_ticket(task, %{title: "Approved title", description: "The body.", priority: :medium, estimate: 2})

    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_revision_plan",
        started_at: DateTime.utc_now()
      })

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, _approved} = Pipeline.approve_plan(system_scope(), run)

    # The issue as Approve left it once the picked design's section is on it.
    {:ok, _issue} = Issues.update_issue(Repo.get!(Issue, issue.id), %{description: "The body.\n\n" <> @design})

    engineer = Repo.get_by!(Run, task_id: task.id, role_id: roles[:engineer].id)
    {:ok, engineer} = Pipeline.update_run(engineer, %{status: :finished, conversation_id: "sess_revision_engineer"})

    %{task: Repo.reload!(task), run: run, engineer: engineer}
  end

  test "a ticket saved after approval reaches the issue once, with the design section carried over", %{
    task: task,
    run: run
  } do
    {:ok, _ticket} =
      Pipeline.save_ticket(task, %{title: "Revised title", description: "The revised body.", priority: :high, estimate: 5})

    assert {:ok, %ImplementationPlan{ticket_revised_at: %DateTime{}, announced_at: %DateTime{} = announced_at}} =
             Pipeline.apply_plan_revision(run)

    description = "The revised body.\n\n" <> @design

    assert %Issue{title: "Revised title", description: ^description, priority: :high, estimate: 5} =
             issue = Repo.get!(Issue, task.issue_id)

    assert {:ok, %ImplementationPlan{announced_at: ^announced_at}} = Pipeline.apply_plan_revision(run)
    assert Repo.get!(Issue, task.issue_id) == issue
  end

  test "a change to the priority or the estimate alone is published", %{task: task, run: run} do
    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Approved title", description: "The body.", estimate: 8})

    assert {:ok, %ImplementationPlan{ticket_revised_at: %DateTime{}}} = Pipeline.apply_plan_revision(run)
    assert %Issue{estimate: 8, priority: :medium} = Repo.get!(Issue, task.issue_id)
  end

  test "a ticket nobody saved since approval leaves an issue edited in Linear alone", %{task: task, run: run} do
    issue = Repo.get!(Issue, task.issue_id)
    issue = issue |> Issue.linear_changeset(%{description: "Rewritten by Linear."}) |> Repo.update!()
    File.touch!(Path.join([task.scratch_path, "tickets", "REV-1.md"]), System.os_time(:second) - 120)

    assert {:ok, %ImplementationPlan{announced_at: nil}} = Pipeline.apply_plan_revision(run)
    assert Repo.get!(Issue, task.issue_id) == issue
  end

  test "a plan saved since the last announcement goes to Engineer as one note with its full text", %{
    task: task,
    run: run,
    engineer: engineer
  } do
    {:ok, engineer} = Pipeline.update_run(engineer, %{status: :running})
    revised = String.replace(@plan, "Extend the module.", "Extend it twice.")
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: revised})

    assert {:ok, %ImplementationPlan{announced_at: %DateTime{} = announced_at, ticket_revised_at: nil}} =
             Pipeline.apply_plan_revision(run)

    note =
      "The plan changed after approval. Build from this from now on.\n\nThe plan, in full:\n\n" <> String.trim(revised)

    assert %Run{pending_chat: ^note} = told = Repo.reload!(engineer)

    assert [%{line: "[plan revised] The plan changed after approval." <> _rest} | _lines] =
             Pipeline.list_run_events(engineer)

    assert {:ok, %ImplementationPlan{announced_at: ^announced_at}} = Pipeline.apply_plan_revision(run)
    assert Repo.reload!(engineer) == told
  end

  test "the divider on Plan's conversation names what went where", %{task: task, run: run, engineer: engineer} do
    {:ok, _engineer} = Pipeline.update_run(engineer, %{status: :running})
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: String.replace(@plan, "Extend the module.", "Extend it twice.")})
    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Revised title", description: "The body."})
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    assert {:ok, %ImplementationPlan{}} = Pipeline.apply_plan_revision(run)

    assert [%{line: "[plan revision " <> divider}] = Pipeline.list_run_events(run)
    assert divider =~ ~r/\A\S+Z\] Plan and ticket to Engineer, ticket to Linear\z/
    assert %Run{pending_chat: "The plan and the ticket changed after approval." <> note} = Repo.reload!(engineer)
    assert note =~ "The ticket, in full:\n\n---\ntitle: Revised title\npriority: medium\nestimate: 2\n---\n\nThe body."
    assert_receive {:output_saved, _task_id}
  end

  test "an Engineer with no conversation is not told, and the divider says the plan was revised", %{
    task: task,
    run: run,
    engineer: engineer
  } do
    Repo.update_all(from(r in Run, where: r.id == ^engineer.id), set: [conversation_id: nil])
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: String.replace(@plan, "Extend the module.", "Extend it twice.")})

    assert {:ok, %ImplementationPlan{announced_at: %DateTime{}}} = Pipeline.apply_plan_revision(run)
    assert [%{line: "[plan revision " <> divider}] = Pipeline.list_run_events(run)
    assert divider =~ ~r/\] Plan revised\z/
    assert %Run{pending_chat: nil} = Repo.reload!(engineer)
  end

  test "at Review, QA or Demo the ticket reaches the issue and no note goes to Engineer", %{
    task: task,
    run: run,
    engineer: engineer
  } do
    for stage <- [:review, :qa, :demo] do
      {:ok, _task} = Pipeline.update_task(task, %{stage: stage})
      {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "At #{stage}", description: "The body."})

      assert {:ok, %ImplementationPlan{}} = Pipeline.apply_plan_revision(run)
      assert %Issue{title: "At " <> _stage} = Repo.get!(Issue, task.issue_id)
    end

    assert Pipeline.list_run_events(engineer) == []
    assert [_review, _qa, %{line: "[plan revision " <> divider}] = Pipeline.list_run_events(run)
    assert divider =~ ~r/\] Ticket revised, ticket to Linear\z/
  end

  test "at Merged or Debugger a revision does nothing", %{task: task, run: run} do
    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Too late", description: "The body."})

    for stage <- [:merged, :debugger] do
      {:ok, _task} = Pipeline.update_task(task, %{stage: stage})

      assert {:ok, nil} = Pipeline.apply_plan_revision(run)
      assert %Issue{title: "Approved title"} = Repo.get!(Issue, task.issue_id)
    end

    assert Pipeline.list_run_events(run) == []
  end

  test "an issue write that fails leaves everything as it was", %{task: task, run: run, engineer: engineer} do
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: String.replace(@plan, "Extend the module.", "Extend it twice.")})
    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Revised title", description: "The body."})
    expect(Issues, :update_issue, fn _issue, _attrs -> {:error, :linear_down} end)

    assert {:error, :linear_down} = Pipeline.apply_plan_revision(run)

    assert %ImplementationPlan{announced_at: nil, ticket_revised_at: nil} =
             Repo.get_by(ImplementationPlan, task_id: task.id)

    assert %Issue{title: "Approved title"} = Repo.get!(Issue, task.issue_id)
    assert Pipeline.list_run_events(run) == []
    assert %Run{pending_chat: nil} = Repo.reload!(engineer)
  end
end
