defmodule Rail.Pipeline.Actions.ApprovePlanTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  # The smallest plan the structure allows: one decision, one card and one criterion, and no data changes.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  ### Decisions

  - Decision: one module changes.

  ### Changes

  #### `lib/rail.ex`

  Extends the module.

  ### Acceptance criteria

  - 1: `lib/rail.ex`

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Git, :branch_fingerprint, fn _worktree_path -> %{head_sha: String.duplicate("a", 40), dirty_digest: "clean"} end)

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
            "issue" => %{"id" => "lin_approve_plan_1", "identifier" => "APP-1", "title" => "Approve Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "The raw ask."})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    # Git is stubbed, so the worktree is only ever looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_ap_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, _ticket} = Pipeline.save_plan(task, %{title: "Approved title", description: "The approved ticket body."})
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_approve_plan",
        started_at: DateTime.utc_now()
      })

    design_dir = Path.join(task.scratch_path, "design")

    # Three options saved, the second picked, and the plan saved again for it.
    picked = fn ->
      File.mkdir_p!(design_dir)

      for key <- ["cards", "table", "timeline"] do
        File.write!(Path.join(design_dir, "#{key}.html"), "<h1>#{key}</h1>")
        File.write!(Path.join(design_dir, "#{key}.png"), "png bytes")
        title = String.capitalize(key)
        {:ok, _option} = Pipeline.save_design_option(task, %{key: key, title: title, summary: "#{title} summary."})
      end

      File.write!(
        Path.join(design_dir, "manifest.json"),
        ~s({"options": [{"key": "table", "title": "Table", "summary": "Dense rows."}]})
      )

      File.rm!(Path.join(design_dir, "cards.html"))
      File.write!(Path.join(design_dir, "picked"), "table")
    end

    uploaded = fn ->
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{
              "success" => true,
              "uploadFile" => %{
                "uploadUrl" => "https://uploads.linear.app/put/app-1",
                "assetUrl" => "https://uploads.linear.app/assets/app-1-table.png",
                "headers" => []
              }
            }
          }
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn ->
        assert {:ok, "png bytes", conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, "")
      end)
    end

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    %{task: task, roles: roles, run: run, design_dir: design_dir, picked: picked, uploaded: uploaded}
  end

  test "with no options it publishes the ticket alone, records the plan and moves the task to Engineer", %{
    task: %{id: task_id} = task,
    roles: roles,
    run: run
  } do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    # The engineer is started by the job committed with the move, not by whoever approved.
    assert %Task{stage: :engineer} = Repo.reload!(task)
    refute Repo.get_by(Run, task_id: task.id, role_id: roles[:engineer].id)
    assert_enqueued(worker: StartEngineer, args: %{task_id: task_id})
    assert :ok = perform_job(StartEngineer, %{task_id: task_id})

    assert %Run{status: :running} = Repo.get_by(Run, task_id: task.id, role_id: roles[:engineer].id)
    assert %Issue{title: "Approved title", description: "The approved ticket body."} = Repo.get!(Issue, task.issue_id)

    plan = String.trim(@plan)

    assert %Round{number: 1, plan: ^plan, approved_at: %DateTime{}, approved_by_id: nil} = Pipeline.read_plan(task)
  end

  test "with a pick it adds the picked design's section and screenshot to the ticket in one write", %{
    task: task,
    run: run,
    picked: picked,
    uploaded: uploaded
  } do
    picked.()
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "table"})
    uploaded.()

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    description =
      "The approved ticket body.\n\n## Design: Table\n\nDense rows.\n\n![Table](https://uploads.linear.app/assets/app-1-table.png)"

    assert %Issue{title: "Approved title", description: ^description} = Repo.get!(Issue, task.issue_id)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a tracker that cannot hold the screenshot still gets the design's section", %{
    task: task,
    run: run,
    picked: picked
  } do
    picked.()
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "table"})
    expect(Issues, :upload_asset, fn _project, _filename, "image/png", _bytes -> {:error, :unsupported} end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    description = "The approved ticket body.\n\n## Design: Table\n\nDense rows."
    assert %Issue{title: "Approved title", description: ^description} = Repo.get!(Issue, task.issue_id)
  end

  test "with Product off it publishes nothing over the issue, which stays the ticket", %{task: task, run: run} do
    Issue |> Repo.get!(task.issue_id) |> Ecto.Changeset.change(skipped_steps: [:product]) |> Repo.update!()

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    assert %Issue{title: "Approve Plan", description: nil} = Repo.get!(Issue, task.issue_id)
    refute_enqueued(worker: Rail.Issues.Workers.SyncIssue)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "with Architect off it is approved with no plan and the task enters Engineer with none recorded", %{
    task: task,
    run: run
  } do
    Issue |> Repo.get!(task.issue_id) |> Ecto.Changeset.change(skipped_steps: [:architect]) |> Repo.update!()
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    assert %Task{stage: :engineer} = Repo.reload!(task)
    assert %Round{number: 1, plan: nil, approved_at: %DateTime{}} = Pipeline.read_plan(task)
    assert %Issue{title: "Approved title"} = Repo.get!(Issue, task.issue_id)
  end

  test "with Product and Architect off a pick alone is approved, adding its section to the issue as it stands", %{
    task: task,
    run: run,
    picked: picked,
    uploaded: uploaded
  } do
    Issue
    |> Repo.get!(task.issue_id)
    |> Ecto.Changeset.change(skipped_steps: [:product, :architect])
    |> Repo.update!()

    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])
    picked.()
    uploaded.()

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(system_scope(), run)

    description = "## Design: Table\n\nDense rows.\n\n![Table](https://uploads.linear.app/assets/app-1-table.png)"

    assert %Issue{title: "Approve Plan", description: ^description} = Repo.get!(Issue, task.issue_id)
  end

  test "a second approval is told the plan is already approved and publishes nothing again", %{task: task, run: run} do
    assert {:ok, _approved} = Pipeline.approve_plan(system_scope(), run)
    {:ok, _issue} = Issues.update_issue(Repo.get!(Issue, task.issue_id), %{description: "Edited in Linear since."})

    assert {:error, :already_approved} = Pipeline.approve_plan(system_scope(), run)
    assert %Issue{description: "Edited in Linear since."} = Repo.get!(Issue, task.issue_id)
  end

  test "is refused without a ticket, or without a plan", %{task: task, run: run} do
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])
    assert {:error, :no_plan} = Pipeline.approve_plan(system_scope(), run)

    Repo.delete_all(from(r in Round, where: r.task_id == ^task.id))
    assert {:error, :no_ticket} = Pipeline.approve_plan(system_scope(), run)

    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "with options and no pick it is refused", %{task: task, run: run, picked: picked, design_dir: dir} do
    picked.()
    File.rm!(Path.join(dir, "picked"))

    assert {:error, :nothing_picked} = Pipeline.approve_plan(system_scope(), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  test "a plan saved before the pick, or for another option, is refused", %{task: task, run: run, picked: picked} do
    picked.()
    assert {:error, :plan_not_for_pick} = Pipeline.approve_plan(system_scope(), run)

    Repo.update_all(from(r in Round, where: r.task_id == ^task.id),
      set: [design: %Round.Design{key: "cards", title: "Cards"}]
    )

    assert {:error, :plan_not_for_pick} = Pipeline.approve_plan(system_scope(), run)
  end

  test "a stale or missing screenshot is not published", %{task: task, run: run, picked: picked, design_dir: dir} do
    picked.()
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "table"})

    File.touch!(Path.join(dir, "table.html"), System.os_time(:second) + 60)
    assert {:error, :stale_screenshot} = Pipeline.approve_plan(system_scope(), run)

    File.rm!(Path.join(dir, "table.png"))
    assert {:error, :screenshot_missing} = Pipeline.approve_plan(system_scope(), run)

    assert %Issue{title: "Approve Plan"} = Repo.get!(Issue, task.issue_id)
  end

  test "an upload Linear refuses leaves the task at Plan with nothing recorded", %{task: task, run: run, picked: picked} do
    picked.()
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "table"})
    Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"fileUpload" => %{"success" => false}}}))

    assert {:error, _reason} = Pipeline.approve_plan(system_scope(), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
    assert %Round{approved_at: nil} = Pipeline.read_plan(task)
    assert %Run{stage_outcome: :done} = Repo.reload!(run)
  end

  test "an empty manifest is no screen, and an issue write that fails leaves the task at Plan", %{
    task: task,
    run: run,
    design_dir: dir
  } do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), ~s({"options": []}))
    expect(Issues, :update_issue, fn _issue, %{title: "Approved title"} -> {:error, :linear_down} end)

    assert {:error, :linear_down} = Pipeline.approve_plan(system_scope(), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
    assert %Round{approved_at: nil} = Pipeline.read_plan(task)
  end

  test "nothing is approved while Plan is still working", %{run: run} do
    {:ok, working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

    assert {:error, :stage_running} = Pipeline.approve_plan(system_scope(), working)
  end

  test "nothing is approved or started while a question waits on an answer", %{task: task, run: run} do
    Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Which cache?"})
    Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Behind a flag?"})

    assert {:error, {:unanswered_questions, 2}} = Pipeline.approve_plan(system_scope(), run)
    assert {:error, {:unanswered_questions, 2}} = Pipeline.start_plan(system_scope(), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
    assert %Round{approved_at: nil} = Pipeline.read_plan(task)
  end

  test "a tech lead without the project cannot approve it, and nobody else can approve at all", %{task: task, run: run} do
    outsider = %{id: "usr_app_outsider", tech_lead: true, admin: false, project_ids: []}

    assert {:error, :not_found} = Pipeline.approve_plan(user_scope(user: outsider), run)
    assert {:error, :not_authorized} = Pipeline.approve_plan(user_scope(admin: true), run)
    assert %Task{stage: :plan} = Repo.reload!(task)
  end

  describe "a tech lead's approval" do
    setup %{project: project, task: task} do
      people =
        Map.new([owner: false, lead: true], fn {who, tech_lead} ->
          {:ok, user} =
            Users.register_oauth_user(%{
              github_id: "gh_app_#{who}",
              login: "#{who}-approve-plan",
              email: "#{who}-approve-plan@example.com"
            })

          {:ok, user} = Users.update_user(system_scope(), user, %{tech_lead: tech_lead, project_ids: [project.id]})
          {who, user_scope(user: user)}
        end)

      Repo.update_all(from(i in Issue, where: i.id == ^task.issue_id), set: [owner_user_id: people.owner.user.id])
      people
    end

    test "waits for the owner to send the plan, then starts the work and records who approved", %{
      task: %Task{id: task_id} = task,
      run: run,
      owner: owner,
      lead: %{user: %{id: lead_id}} = lead
    } do
      assert {:error, :plan_not_ready} = Pipeline.approve_plan(lead, run)
      assert %Task{stage: :plan} = Repo.reload!(task)

      {:ok, _sent} = Pipeline.send_plan_to_lead(owner, run)

      assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(lead, run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
      assert_enqueued(worker: StartEngineer, args: %{task_id: task_id})
      assert %Round{approved_at: %DateTime{}, approved_by_id: ^lead_id} = Pipeline.read_plan(task)
      assert [] = Pipeline.list_tasks(project_id: task.project_id, plan_ready: true)
    end

    test "needs no send when the lead owns the task", %{task: task, run: run, lead: %{user: %{id: lead_id}} = lead} do
      Repo.update_all(from(i in Issue, where: i.id == ^task.issue_id), set: [owner_user_id: lead_id])

      assert {:ok, %Run{}} = Pipeline.approve_plan(lead, run)
      assert %Round{approved_at: %DateTime{}, approved_by_id: ^lead_id, ready_at: nil} = Pipeline.read_plan(task)
    end

    test "waits on the lead's own unsent comments, which approving would delete, not on anyone else's", %{
      task: task,
      run: run,
      owner: owner,
      lead: %{user: %{id: lead_id}} = lead
    } do
      Repo.update_all(from(i in Issue, where: i.id == ^task.issue_id), set: [owner_user_id: lead_id])

      comment = %{
        target: :plan,
        element_kind: :section_title,
        element_label: "Approach",
        element_occurrence: 1,
        element_text: "Approach",
        body: "Why?"
      }

      {:ok, _theirs} = Pipeline.create_plan_comment(owner, run, comment)
      {:ok, first} = Pipeline.create_plan_comment(lead, run, comment)
      {:ok, second} = Pipeline.create_plan_comment(lead, run, %{comment | body: "And how?"})

      assert {:error, {:unsent_comments, 2}} = Pipeline.approve_plan(lead, run)
      assert %Task{stage: :plan} = Repo.reload!(task)
      assert [_first, _second] = Pipeline.list_plan_comments(lead, task)

      for comment <- [first, second], do: {:ok, _removed} = Pipeline.delete_plan_comment(lead, comment)

      assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_plan(lead, run)
      assert Pipeline.list_plan_comments(owner, task) == []
    end

    test "on work its owner already started only records the approval, once, on the first round", %{
      task: %Task{id: task_id} = task,
      run: run,
      owner: owner,
      lead: %{user: %{id: lead_id}} = lead
    } do
      {:ok, _started} = Pipeline.start_plan(owner, run)
      {:ok, _later} = Pipeline.create_round(task)
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

      # Nothing is stubbed for Linear, so publishing again would fail the test.
      assert {:ok, %Run{}} = Pipeline.approve_plan(lead, run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
      assert_received {:pipeline_changed, ^task_id}

      assert [%Round{number: 1, approved_at: %DateTime{}, approved_by_id: ^lead_id}, %Round{number: 2, approved_at: nil}] =
               Pipeline.list_rounds(task)

      assert {:error, :already_approved} = Pipeline.approve_plan(lead, run)
    end

    test "on a started task is refused for a project the lead cannot open, or a task with no plan", %{
      task: task,
      run: run
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})
      outsider = %{id: "usr_app_outsider", tech_lead: true, admin: false, project_ids: []}

      assert {:error, :not_found} = Pipeline.approve_plan(user_scope(user: outsider), run)

      Repo.delete_all(from(r in Round, where: r.task_id == ^task.id))
      assert {:error, :no_plan} = Pipeline.approve_plan(system_scope(), run)
    end
  end

  test "the ticket's priority and estimate go to the issue with its title and description", %{task: task, run: run} do
    {:ok, _ticket} =
      Pipeline.save_plan(task, %{
        title: "Approved title",
        description: "The approved ticket body.",
        priority: :high,
        estimate: 3
      })

    assert {:ok, %Run{}} = Pipeline.approve_plan(system_scope(), run)

    assert %Issue{title: "Approved title", description: "The approved ticket body.", priority: :high, estimate: 3} =
             Repo.get!(Issue, task.issue_id)
  end

  test "an approval deletes every author's unsent comments, since the conversation they go to closes", %{
    task: %{id: task_id} = task,
    run: run
  } do
    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_app_ada",
        login: "ada-approve-plan",
        email: "ada-approve-plan@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_app_grace",
        login: "grace-approve-plan",
        email: "grace-approve-plan@example.com"
      })

    [ada, grace] = Enum.map([ada, grace], &user_scope(user: &1))

    comment = %{
      target: :ticket,
      element_kind: :title,
      element_label: "Title",
      element_occurrence: 1,
      element_text: "Approved title",
      body: "Shorter."
    }

    for author <- [ada, grace], do: {:ok, _comment} = Pipeline.create_plan_comment(author, run, comment)
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{ada.user.id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{grace.user.id}")

    assert {:ok, %Run{}} = Pipeline.approve_plan(system_scope(), run)

    assert Pipeline.list_plan_comments(ada, task) == []
    assert Pipeline.list_plan_comments(grace, task) == []
    assert_receive {:plan_comments_changed, ^task_id}
    assert_receive {:plan_comments_changed, ^task_id}
  end

  test "a refused approval leaves unsent comments where they were", %{task: task, run: run} do
    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_app_ada2", login: "ada2", email: "ada2@example.com"})
    ada = user_scope(user: ada)

    {:ok, %{id: id}} =
      Pipeline.create_plan_comment(ada, run, %{
        target: :plan,
        element_kind: :section_title,
        element_label: "Approach",
        element_occurrence: 1,
        element_text: "Approach",
        body: "Why?"
      })

    Repo.delete_all(from(r in Round, where: r.task_id == ^task.id))

    assert {:error, :no_ticket} = Pipeline.approve_plan(system_scope(), run)
    assert [%{id: ^id}] = Pipeline.list_plan_comments(ada, task)
  end
end
