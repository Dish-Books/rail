defmodule RailWeb.Live.RunConversationTest do
  use Rail.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias RailWeb.Live.RunConversation

  setup %{project: project} do
    roles =
      Map.new([:plan, :product, :design, :architect, :engineer], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_conversation_1",
              "identifier" => "CNV-1",
              "title" => "Conversation Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Conversation Issue"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    roles_map = Map.new(roles, fn {_stage, role} -> {role.id, role} end)

    # An account offering `model` that the conversation can name, its windows read as the
    # probe left them: `{label, percent left, resets_at}`.
    signed_in = fn model, windows, attrs ->
      {:ok, backend} =
        Tools.create_backend(system_scope(), %{
          name: :claude,
          label: attrs[:label],
          executable_path: "/usr/bin/true",
          models: [%{id: model}]
        })

      groups =
        Enum.map(windows, fn {label, left, resets_at} ->
          window = %{"label" => label, "remaining_percent" => left, "resets_at" => DateTime.to_iso8601(resets_at)}
          %{name: label, details: %{"windows" => [window]}}
        end)

      backend
      |> Backend.usage_changeset(%{name: :claude, status: attrs[:status] || :ready, usage: groups})
      |> Repo.update!()
    end

    %{project: project, task: task, roles: roles, roles_map: roles_map, signed_in: signed_in}
  end

  test "says so when the role on the tab has not run the task", %{task: task, roles_map: roles_map} do
    html = render_component(RunConversation, id: "conv", task: task, runs: [], roles_map: roles_map)

    assert html =~ ~s(data-qa="conversation_empty_state")
    assert html =~ "This role has not run on the task yet."
  end

  test "names the role being read and describes its run", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, architect} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: ~U[2026-09-09 09:00:00.000000Z],
        completed_at: ~U[2026-09-09 09:05:00.000000Z]
      })

    {:ok, engineer} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_engineer",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [architect, engineer],
        roles_map: roles_map
      )

    # The most recent run is the one being read.
    assert html =~ ~s(id="conversation-role-#{engineer.role_id}")
    refute html =~ ~s(id="conversation-role-#{architect.role_id}")
    assert html =~ "running"
    assert html =~ "conversation conv_engineer"
  end

  test "renders each kind of thing said in the conversation", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, architect} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: ~U[2026-09-09 09:00:00.000000Z]
      })

    {:ok, engineer} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_engineer",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(
      engineer.id,
      nil,
      [
        "[human] Please implement the OAuth callback handler",
        "[run] Runner started execution",
        "I will start by reviewing the router.",
        "[tool read_file] lib/rail_web/router.ex",
        "[tool read_file] lib/rail_web/user_auth.ex",
        "Follow the schema plan closely.",
        "[rail] Automated check completed"
      ]
    )

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [architect, engineer],
        roles_map: roles_map
      )

    assert html =~ ~s(data-qa="human-bubble")
    assert html =~ "Please implement the OAuth callback handler"
    assert html =~ ~s(data-qa="role-bubble")
    assert html =~ "I will start by reviewing the router."
    assert html =~ ~s(data-qa="activity-tile")
    assert html =~ "Tool activity (2 steps)"
    refute html =~ ~s(data-qa="activity-content")
    assert html =~ ~s(data-qa="rail-event")
    assert html =~ ~s(data-qa="system-event")
  end

  # Everyone on the task reads the same conversation, so "You" is only the reader.
  test "a person's message is theirs: You for the reader, their name for anyone else", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, %{id: dana_id}} =
      Rail.Users.register_oauth_user(%{
        github_id: "gh_cnv_dana",
        login: "dana",
        name: "Dana Reyes",
        email: "d@example.com"
      })

    {:ok, %{id: reader_id} = reader} =
      Rail.Users.register_oauth_user(%{github_id: "gh_cnv_reader", login: "reader", email: "r@example.com"})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_shared",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      "[human] Written before senders were kept.",
      "[human:#{dana_id}] 3 comments on the diff",
      "[human:usr_gone] From someone since removed.",
      "[human:#{reader_id}] My own follow-up."
    ])

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [run],
        roles_map: roles_map,
        current_scope: user_scope(user: reader)
      )

    assert ["You", "Dana Reyes", "Someone", "You"] =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("[data-qa='human-bubble-sender']")
             |> Enum.map(&String.trim(Floki.text(&1)))
  end

  # What Rail sent on its own is a message to the agent like a person's, but it
  # says it was Rail and which reminder it was.
  test "a note Rail sent the agent by itself reads as Rail's, not as the human's", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_reminded",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      "[rail] 1 finding had no evidence, so the report went back to QA (1 of 2).",
      "[reminder 1 of 2] This report is not valid yet.",
      "[reminder 1 of 2]",
      "[reminder 1 of 2] - Export button stays enabled (export-button-enabled): no evidence attached."
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert [bubble] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='reminder-bubble']")
    assert Floki.text(bubble) =~ ~r/Rail, automatically\s*· reminder 1 of 2/
    assert Floki.text(bubble) =~ "This report is not valid yet.\n\n- Export button stays enabled"
    refute html =~ ~s(data-qa="human-bubble")
  end

  test "a round Rail answered from past answers reads as Rail's, not as the viewer's", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_past_answers",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      "[answered from past answers] You asked: Which database?",
      "[answered from past answers] Answered by Rail from Dana's answer on RAIL-65, Oct 3: Postgres."
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert [bubble] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='reminder-bubble']")
    assert Floki.text(bubble) =~ ~r/Rail, automatically\s*· answered from past answers/
    assert Floki.text(bubble) =~ "Answered by Rail from Dana's answer on RAIL-65, Oct 3: Postgres."
    refute html =~ ~s(data-qa="human-bubble")
  end

  test "reads the agent's stream as a conversation, not as JSON", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_stream",
        started_at: ~U[2026-09-09 10:00:00.000000Z],
        completed_at: ~U[2026-09-09 10:01:05.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      ~s({"type":"system","subtype":"init","session_id":"conv_stream","tools":[]}),
      ~s({"type":"assistant","message":{"content":[{"type":"text","text":"## Plan\\n\\n- **One** step"}]}}),
      ~s({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/a.ex"}}]}}),
      "[human] Looks good"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    refute html =~ "&quot;type&quot;"
    assert html =~ "<strong>One</strong>"
    assert html =~ "Tool activity (1 step)"
    assert html =~ "Looks good"
  end

  # The run's own started_at is reset by every turn, so the figure a reader wants
  # is the turns added up, not the last one.
  test "the elapsed time is every turn the agent took, added up", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:30:00.000000Z],
        completed_at: ~U[2026-09-09 10:30:20.000000Z]
      })

    for {started, ended} <- [
          {~U[2026-09-09 10:00:00.000000Z], ~U[2026-09-09 10:01:05.000000Z]},
          {~U[2026-09-09 10:30:00.000000Z], ~U[2026-09-09 10:30:20.000000Z]}
        ] do
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/#{run.id}.ndjson",
        status: :finished,
        started_at: started
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(updated_at: ended)
      |> Repo.update!()
    end

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-elapsed-seconds="85")
    assert html =~ "1m 25s"
    refute html =~ "data-started-at"
  end

  test "a turn still running keeps counting in the browser", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: ~U[2026-09-09 10:30:00.000000Z]
      })

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: task.id,
      stream_path: "/tmp/#{run.id}.ndjson",
      status: :running,
      started_at: ~U[2026-09-09 10:30:00.000000Z]
    })
    |> Repo.insert!()

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-started-at="2026-09-09T10:30:00.000000Z")
    assert html =~ ~s(data-elapsed-seconds="0")
  end

  test "each turn is marked in the transcript with when it started and what it cost", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    first =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/#{run.id}.ndjson",
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(updated_at: ~U[2026-09-09 10:00:30.000000Z])
      |> Repo.update!()

    second =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/#{run.id}.ndjson",
        status: :finished,
        started_at: ~U[2026-09-09 11:00:00.000000Z]
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(updated_at: ~U[2026-09-09 11:02:00.000000Z])
      |> Repo.update!()

    Pipeline.append_run_events(run.id, first.id, ["[rail] the first turn", "[rail] still the first turn"])
    Pipeline.append_run_events(run.id, second.id, ["[rail] the second turn"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-qa="turn-start")
    assert html =~ "Turn 1"
    assert html =~ "Turn 2"
    assert html =~ "30s"
    assert html =~ "2m 0s"
    assert html =~ ~s(data-at="2026-09-09T11:00:00.000000Z")
    assert html =~ "still the first turn"
  end

  test "a setup script reads as its output in one block, not as a turn of the agent's", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :failed,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    setup =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :setup,
        command: "./scripts/setup-worktree.sh",
        exit_code: 1,
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })
      |> Repo.insert!()

    Pipeline.append_run_events(run.id, setup.id, ["Worktree slot \e[1m3\e[0m", "Cannot copy dishbooks_dev"])
    Pipeline.append_run_events(run.id, nil, ["[rail] the stage was not entered"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    refute html =~ ~s(data-qa="turn-start")
    assert html =~ ~s(data-qa="command-block")
    assert html =~ "./scripts/setup-worktree.sh"
    assert html =~ "Failed · exit 1"
    assert html =~ "Worktree slot 3\nCannot copy dishbooks_dev"
    assert html =~ ~s(data-qa="rail-event")
  end

  test "a CI run reads as CI", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    ci =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        command: "mise run ci",
        exit_code: 0,
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Pipeline.append_run_events(run.id, ci.id, ["all gates passed"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~r/>\s*CI\s*</
    assert html =~ "mise run ci"
  end

  test "a setup script that passed keeps its output folded away until asked", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    setup =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :setup,
        command: "./bin/setup",
        exit_code: 0,
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })
      |> Repo.insert!()

    Pipeline.append_run_events(run.id, setup.id, ["all set"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ "Passed"
    refute html =~ ~s(data-qa="command-output")
  end

  test "a setup script says whether it is still going or was stopped", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    for {status, exit_code, line} <- [
          {:finished, -1, "was stopped"},
          {:finished, 124, "ran out of time"},
          {:running, nil, "still copying"}
        ] do
      setup =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: run.id,
          task_id: task.id,
          kind: :setup,
          command: "./bin/setup",
          exit_code: exit_code,
          stream_path: "/tmp/#{run.id}-#{status}.log",
          status: status,
          started_at: ~U[2026-09-09 10:00:00.000000Z]
        })
        |> Repo.insert!()

      Pipeline.append_run_events(run.id, setup.id, [line])
    end

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ "Stopped"
    assert html =~ "Timed out"
    assert html =~ "Running"
    assert html =~ ~s(phx-hook="Elapsed" data-started-at="2026-09-09T10:00:00.000000Z")
    assert html =~ "still copying"
  end

  # The page's tab says which run is being read, and a role whose turn has not
  # come has nothing to show rather than somebody else's transcript.
  test "a tab whose role has not run reads as nothing, not as the last run", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, ["Plain words from the agent."])

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [run],
        roles_map: roles_map,
        stage_run: nil
      )

    refute html =~ "Plain words from the agent."
  end

  test "tool activity names each step, reads paths from the worktree root and flags errors", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/work/tree"})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_tools",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      "[tool] Read /work/tree/lib/rail.ex",
      "[tool] Bash mix test",
      "[tool] Read /work/tree/lib/rail_web.ex",
      "[tool error] File not found"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ "Tool activity (3 steps)"
    assert html =~ "Read ×2, Bash"
    assert html =~ "pi-warning-circle"
  end

  test "Rail's own tools read by their names, a refused save among them", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_saves",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      "[tool] mcp__rail__save_finding comment-saved-during-send · major",
      "[tool] mcp__rail__save_finding round-query-scope · high",
      ~s([tool error mcp__rail__save_finding] Refused, nothing saved. severity: "high" is not one of blocker, major, minor, nit.),
      "[tool] Read lib/rail.ex"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    # A refused call is one call: its error line is flagged, never counted again.
    assert html =~ "Tool activity (3 steps)"
    assert html =~ "save_finding ×2, Read"
    refute html =~ "mcp__rail__"
    assert html =~ "pi-warning-circle"
  end

  test "the composer says the agent is thinking, and offers to stop it", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_thinking",
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="thinking-banner")
    assert html =~ ~s(id="stop-run")
    refute html =~ ~s(id="queued-banner")
  end

  describe "a turn waiting for resources" do
    setup %{task: task, roles: roles} do
      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :waiting_for_resources,
          conversation_id: "conv_waiting",
          started_at: ~U[2026-09-09 14:27:00.000000Z]
        })

      os_process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: task.id,
          stream_path: "/tmp/#{run.id}.ndjson",
          status: :waiting_for_resources,
          started_at: ~U[2026-09-09 14:27:00.000000Z],
          queued_at: ~U[2026-09-09 14:27:00.000000Z],
          reserved_cpus: 2,
          reserved_memory_gb: 4
        })

      %{run: run, os_process: os_process}
    end

    test "says so in the composer, the header and the transcript, and offers to stop it", %{
      task: task,
      run: run,
      os_process: os_process,
      roles_map: roles_map
    } do
      Pipeline.append_run_events(run.id, os_process.id, ["[rail] Turn 1 needs 2 CPUs and 4 GB."])

      html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

      assert html =~ ~s(id="waiting-banner")
      assert html =~ "engineer role is waiting for resources · 1st in line ·"
      assert html =~ ~s(data-started-at="2026-09-09T14:27:00.000000Z")
      assert html =~ ~s(id="stop-run")
      refute html =~ ~s(id="thinking-banner")
      assert html =~ ~s(data-qa="conversation-state-dot" data-state="waiting")
      assert html =~ "waiting for resources since"
      assert html =~ ~s(data-at="2026-09-09T14:27:00.000000Z")
    end

    test "a command waiting for resources says so rather than that it runs", %{
      task: task,
      run: run,
      os_process: os_process,
      roles_map: roles_map
    } do
      os_process |> Ecto.Changeset.change(kind: :ci, command: "mix ci") |> Repo.update!()
      Pipeline.append_run_events(run.id, os_process.id, ["[rail] CI needs 2 CPUs and 4 GB."])

      html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

      assert html =~ "Waiting for resources"
      refute html =~ ">\n            Running\n"
    end
  end

  test "the role row names the model and the account the conversation is on, with its tightest window, and each turn names its account",
       %{signed_in: signed_in, task: task, roles: roles, roles_map: roles_map} do
    work =
      signed_in.(
        "claude-opus-5-5",
        [
          {"Session", 90.0, DateTime.shift(DateTime.utc_now(), hour: 3)},
          {"Weekly", 31.0, DateTime.shift(DateTime.utc_now(), day: 4)}
        ],
        %{label: "work"}
      )

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: ~U[2026-09-09 14:05:00.000000Z]
      })

    turn =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task.id,
        backend_id: work.id,
        stream_path: "/tmp/#{run.id}.ndjson",
        status: :running,
        started_at: ~U[2026-09-09 14:05:00.000000Z]
      })

    Pipeline.append_run_events(run.id, turn.id, ["[rail] working"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~r/id="conversation-model"[^>]*>\s*claude-opus-5-5/
    assert html =~ ~r/id="conversation-account"[^>]*title="Claude Code · work"/
    assert html =~ ~r/id="conversation-account".*<span class="truncate">work<\/span>.*Weekly 31%/s
    assert html =~ ~r/data-qa="turn-account">Claude Code · work</
  end

  describe "a turn waiting for usage" do
    setup %{task: task, roles: roles, roles_map: roles_map} do
      model = "claude-usage-#{System.unique_integer([:positive])}"
      {:ok, engineer} = Roles.update_role(system_scope(), roles[:engineer], %{model: model})
      soon = DateTime.utc_now() |> DateTime.shift(hour: 2) |> DateTime.truncate(:second)
      later = DateTime.utc_now() |> DateTime.shift(day: 3) |> DateTime.truncate(:second)

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: engineer.id,
          status: :waiting_for_usage,
          started_at: ~U[2026-09-09 14:04:00.000000Z]
        })

      %{
        engineer: engineer,
        later: later,
        model: model,
        roles_map: Map.put(roles_map, engineer.id, engineer),
        run: run,
        soon: soon
      }
    end

    test "lists every account offering the model with its spent window and reset, the earliest first", %{
      signed_in: signed_in,
      task: task,
      model: model,
      roles_map: roles_map,
      run: run,
      soon: soon,
      later: later
    } do
      max = signed_in.(model, [{"Session", 0.0, soon}], %{label: "max-2"})
      work = signed_in.(model, [{"Weekly", 0.0, later}], %{label: "work"})
      ops = signed_in.(model, [], %{label: "ops", status: :signed_out})
      # Reset since the turn last tried, and not yet tried again.
      _roomy = signed_in.(model, [{"Weekly", 15.0, later}], %{label: "roomy"})
      _down = signed_in.(model, [], %{label: "down", status: :unavailable})

      waiting =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: task.id,
          stream_path: "/tmp/#{run.id}.ndjson",
          status: :waiting_for_usage,
          started_at: ~U[2026-09-09 14:04:00.000000Z],
          queued_at: ~U[2026-09-09 14:04:00.000000Z]
        })

      Pipeline.append_run_events(run.id, waiting.id, [
        "[rail] Every signed-in account offering #{model} has used up its usage."
      ])

      html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

      assert html =~ "waiting for usage since"
      assert html =~ ~s(data-qa="conversation-state-dot" data-state="waiting_for_usage")
      assert html =~ ~r/id="conversation-account".*no account yet/s
      assert html =~ "#{model} is used up on every signed-in account"

      assert [max_row, work_row, roomy_row, ops_row, down_row] =
               html |> Floki.parse_fragment!() |> Floki.find("[data-qa=usage-wait-account]") |> Enum.map(&Floki.text/1)

      assert roomy_row =~ "Weekly 15%" and roomy_row =~ "has room again"
      assert down_row =~ "unavailable" and down_row =~ "not waited on"

      assert max_row =~ "Claude Code · max-2" and max_row =~ "5-hour 0%"
      assert work_row =~ "Claude Code · work" and work_row =~ "Weekly 0%"
      assert ops_row =~ "Claude Code · ops" and ops_row =~ "signed out" and ops_row =~ "not waited on"
      assert html =~ ~r/id="usage-reset-#{max.id}"[^>]*data-earliest="true"/
      assert html =~ ~r/id="usage-reset-#{work.id}"[^>]*data-earliest="false"/
      refute html =~ ~s(id="usage-reset-#{ops.id}")

      assert html =~ ~s(id="usage-banner")
      assert html =~ "engineer role is waiting for usage"
      assert html =~ ~s(id="usage-banner-starts-at")
      assert html =~ ~s(data-at="#{DateTime.to_iso8601(soon)}")
      refute html =~ ~s(id="waiting-banner")
      refute html =~ ~s(id="usage-wait-stop")
    end

    test "a run that has just stopped waiting shows no wait", %{task: task, roles_map: roles_map, run: run} do
      html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

      refute html =~ ~s(id="usage-banner")
      refute html =~ ~s(id="usage-wait-card")
    end

    test "a resumed conversation waits on its own account, and offers to stop", %{
      signed_in: signed_in,
      task: task,
      model: model,
      roles_map: roles_map,
      run: run,
      later: later
    } do
      work = signed_in.(model, [{"Weekly", 0.0, later}], %{label: "work"})
      _elsewhere = signed_in.(model, [], %{label: "max-2"})
      {:ok, run} = Pipeline.update_run(run, %{conversation_id: "conv_pinned"})

      answered =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: task.id,
          backend_id: work.id,
          stream_path: "/tmp/#{run.id}.ndjson",
          status: :finished,
          started_at: ~U[2026-09-09 13:31:00.000000Z]
        })

      waiting =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: task.id,
          backend_id: work.id,
          stream_path: "/tmp/#{run.id}.ndjson",
          status: :waiting_for_usage,
          started_at: ~U[2026-09-09 14:10:00.000000Z],
          queued_at: ~U[2026-09-09 14:10:00.000000Z]
        })

      Pipeline.append_run_events(run.id, answered.id, ["[rail] the answered turn"])
      Pipeline.append_run_events(run.id, waiting.id, ["[rail] This conversation lives on Claude Code · work."])

      html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

      assert html =~ ~r/title="Claude Code · work">\s*This conversation lives on the work account/
      assert html =~ ~s(id="usage-wait-stop")

      assert [only] =
               html |> Floki.parse_fragment!() |> Floki.find("[data-qa=usage-wait-account]") |> Enum.map(&Floki.text/1)

      assert only =~ "Claude Code · work" and only =~ "Weekly 0%"
      refute html =~ "max-2"
      assert html =~ ~r/data-qa="turn-account">Claude Code · work</
    end
  end

  # A 400px floor overruns the column on an iPad, stacked or in landscape, and pushes the composer out.
  test "the chat pane takes whatever height its column leaves", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_pane_height",
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert [class] = html |> Floki.parse_fragment!() |> Floki.attribute("#chat-pane-root", "class")
    classes = String.split(class)
    assert "min-h-0" in classes
    refute Enum.any?(classes, &(String.starts_with?(&1, "lg:min-h-") or String.starts_with?(&1, "min-h-[")))
  end

  test "wide agent replies and events wrap inside the sidebar, and code and tables keep their own box", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_wide",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    long = String.duplicate("a", 200)
    columns = Enum.map_join(1..12, " | ", &"column_#{&1}")

    reply =
      Enum.join(
        [
          "See https://example.com/#{long}",
          "Edit `lib/rail_web/live/#{long}.ex`",
          "```\n#{long}\n```",
          "| #{columns} |\n|#{String.duplicate(" --- |", 12)}\n| #{columns} |"
        ],
        "\n\n"
      )

    Pipeline.append_run_events(run.id, nil, [
      ~s({"type":"assistant","message":{"content":[{"type":"text","text":#{Jason.encode!(reply)}}]}}),
      "[tool read_file] lib/rail.ex",
      "[error] could not open /srv/#{long}/file.ex",
      "[rail] That message was not delivered: #{long}",
      "[stderr] warning: could not read /srv/#{long}.beam"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)
    doc = Floki.parse_fragment!(html)

    assert [pane] = Floki.attribute(doc, "#chat-messages", "class")
    assert ["overflow-y-auto", "overflow-x-hidden"] -- String.split(pane) == []

    assert [body] = Floki.attribute(doc, "[data-qa='role-bubble'] [data-qa='markdown-body']", "class")
    assert ["wrap-break-word", "prose-table:block", "prose-table:overflow-x-auto"] -- String.split(body) == []

    assert Floki.find(doc, "[data-qa='role-bubble'] pre") != []
    assert Floki.find(doc, "[data-qa='role-bubble'] table") != []

    assert [summary] = Floki.attribute(doc, "[data-qa='activity-tile'] button span.truncate", "class")
    refute "wrap-break-word" in String.split(summary)

    for selector <- ["[data-qa='error-event'] span.select-text", "[data-qa='rail-event'] span.select-text"] do
      assert [class] = Floki.attribute(doc, selector, "class")
      assert ["min-w-0", "wrap-break-word"] -- String.split(class) == []
    end

    assert [system] = Floki.attribute(doc, "[data-qa='system-event']", "class")
    assert "wrap-break-word" in String.split(system)
  end

  test "a message waiting on a working agent stacks under the thinking banner", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_queued",
        pending_chat: "Please add a test",
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="thinking-banner")
    assert html =~ ~s(id="queued-banner")
    assert html =~ ~s(id="send-queued-now")
    assert html =~ "Please add a test"
  end

  test "a run whose role is unknown still reads, with what it spent", %{task: task, roles: roles} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_unknown_role",
        usage: %{input_tokens: 1200, output_tokens: 300},
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, ["Plain words from the agent."])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: %{})

    assert html =~ ~s(id="metadata-run-usage")
    assert html =~ "Plain words from the agent."
    assert html =~ ~s(id="conversation-role-#{run.role_id}")
  end

  test "a run with no conversation cannot be chatted with, but its stage can be retried", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="unavailable-banner")
    assert html =~ "has not started a conversation"
    assert html =~ ~s(id="retry-run")

    # A stage the task has left is not entered again from here.
    {:ok, planning} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [planning], roles_map: roles_map)

    assert html =~ ~s(id="unavailable-banner")
    refute html =~ ~s(id="retry-run")
  end

  test "a run that failed says why in the conversation", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        error: "claude reported error_during_execution: Eligibility check failed",
        started_at: DateTime.utc_now()
      })

    Pipeline.append_run_events(run.id, nil, [
      ~s({"type":"result","subtype":"error_during_execution","is_error":true,"result":"Eligibility check failed"})
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-qa="error-event")
    assert html =~ "claude reported error_during_execution: Eligibility check failed"

    # A result that spent nothing says only its status, with no dangling separator.
    assert html =~ ~r/\[result\] error_during_execution\s*</
  end

  test "a subagent is a line with its role, its description and what it saved, open while it works", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :plan})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :running,
        conversation_id: "conv_plan",
        started_at: DateTime.utc_now()
      })

    call = fn id, type, description ->
      ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"#{id}","name":"Task","input":{"subagent_type":"#{type}","description":"#{description}"}}]}})
    end

    within = fn id, block -> ~s({"type":"assistant","parent_tool_use_id":"#{id}","message":{"content":[#{block}]}}) end

    Pipeline.append_run_events(run.id, nil, [
      call.("toolu_pm", "product", "wrote the ticket"),
      within.("toolu_pm", ~s({"type":"text","text":"Reading the issue."})),
      within.("toolu_pm", ~s({"type":"tool_use","id":"toolu_t","name":"mcp__rail__save_ticket","input":{"title":"T"}})),
      ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_pm","content":"Saved."}]}}),
      call.("toolu_ar", "architect", "plan from the ticket"),
      within.("toolu_ar", ~s({"type":"tool_use","id":"toolu_p","name":"mcp__rail__save_plan","input":{"plan":"x"}})),
      ~s({"type":"user","parent_tool_use_id":"toolu_ar","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_p","is_error":true,"content":"Refused, nothing saved. plan: must open with the heading."}]}}),
      ~s({"type":"assistant","message":{"content":[{"type":"text","text":"The ticket is saved."}]}})
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], stage_run: run, roles_map: roles_map)

    assert html =~
             ~r/id="subagent-[^"]+" data-qa="subagent-block" data-status="done".*product role.*wrote the ticket.*ticket saved/s

    # Plan is still working, so the Designer may yet be handed its part: nothing reads as skipped.
    refute html =~ ~s(data-status="skipped")
    assert html =~ ~r/data-status="running".*architect role.*plan from the ticket/s

    # The finished Product line is closed; the Architect still working is open on its own transcript.
    refute html =~ "Reading the issue."
    assert html =~ ~s(data-qa="subagent-transcript")
    assert html =~ ~r/id="activity-tile-1-0".*save_plan.*pi-warning-circle/s
    assert html =~ "The ticket is saved."
  end

  test "a stopped Plan run with no options saved says the Designer was skipped, before the Architect's line", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Pipeline.append_run_events(run.id, nil, [
      "[subagent toolu_p] product · write the ticket",
      "[subagent end toolu_p]",
      "[subagent toolu_a] architect · plan from the ticket",
      "[subagent end toolu_a]"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], stage_run: run, roles_map: roles_map)

    assert html =~ ~r/product role.*data-status="skipped".*design role.*no screen changes in this task.*architect role/s
  end

  test "an Architect handed its part before the Designer does not make the design read as skipped", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    File.write!(Path.join(design_dir, "manifest.json"), ~s({"options": [{"key": "rows", "title": "Rows"}]}))

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Pipeline.append_run_events(run.id, nil, [
      "[subagent toolu_a] architect · plan from the ticket",
      "[subagent toolu_d] designer · three options",
      "[subagent end toolu_a]",
      "[subagent end toolu_d]"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], stage_run: run, roles_map: roles_map)

    assert html =~ ~r/architect role.*design role.*three options/s
    refute html =~ ~s(data-status="skipped")
  end

  test "a subagent with a type Rail does not know reads by its type", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        conversation_id: "conv_general",
        started_at: DateTime.utc_now()
      })

    Pipeline.append_run_events(run.id, nil, [
      "[subagent toolu_g] general-purpose · look around",
      "[subagent end toolu_g] Ran out",
      "[subagent toolu_d] designer · three options",
      "[within toolu_d] [tool] mcp__rail__save_design_option rows",
      "[within toolu_d] [tool] mcp__rail__save_design_option rows",
      "[subagent end toolu_d]",
      "[subagent toolu_a] architect · plan for Rows"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], stage_run: run, roles_map: roles_map)

    assert html =~ ~r/data-status="failed".*General Purpose.*look around/s

    # A Designer line before the Architect's means there was a screen, so none is marked skipped; a re-save is one option.
    assert html =~ ~r/data-status="done".*design role.*three options.*1 option/s
    refute html =~ "skipped"
  end

  test "a Plan run with no conversation can be retried, since its brief starts it again", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :plan})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:plan].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="retry-run")
  end

  describe "plan comments" do
    setup %{task: task, roles: roles} do
      dir = Path.join(task.scratch_path, "design")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(task.scratch_path) end)

      File.write!(
        Path.join(dir, "manifest.json"),
        ~s({"options": [{"key": "waiting-lanes", "title": "Lanes by what they wait on"}]})
      )

      File.write!(Path.join(dir, "picked"), "waiting-lanes")

      {:ok, plan} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:plan].id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "conv_plan_comments",
          started_at: DateTime.utc_now()
        })

      {:ok, reader} =
        Rail.Users.register_oauth_user(%{github_id: "gh_cnv_pcm", login: "maya", name: "Maya", email: "m@example.com"})

      scope = user_scope(user: reader)

      {:ok, _comment} =
        Pipeline.create_plan_comment(scope, plan, %{
          target: :design,
          option_key: "waiting-lanes",
          selector: "#group-by-project",
          element_text: "Group by project",
          element_tag: "label",
          capture: %{html: "<label>Group by project</label>", width: 160, height: 20},
          body: "Turn this on by default."
        })

      %{plan: plan, scope: scope}
    end

    test "the reader's unsent comments wait above the composer on the Plan run, and on no other run", %{
      task: task,
      roles: roles,
      roles_map: roles_map,
      plan: plan,
      scope: scope
    } do
      html =
        render_component(RunConversation,
          id: "conv",
          task: task,
          runs: [plan],
          roles_map: roles_map,
          current_scope: scope
        )

      doc = Floki.parse_fragment!(html)

      assert doc |> Floki.find("#plan-comment-tray") |> Floki.text() =~ "Turn this on by default."
      assert doc |> Floki.find("#send-plan-comments") |> Floki.text() =~ "Send 1"
      assert :binary.match(html, "plan-comment-tray") < :binary.match(html, "composer-root")

      {:ok, engineer} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          status: :finished,
          conversation_id: "conv_engineer_pcm",
          started_at: DateTime.utc_now()
        })

      html =
        render_component(RunConversation,
          id: "conv",
          task: task,
          runs: [engineer],
          roles_map: roles_map,
          current_scope: scope
        )

      refute html =~ "plan-comment-tray"

      html = render_component(RunConversation, id: "conv", task: task, runs: [plan], roles_map: roles_map)
      refute html =~ "plan-comment-tray"
    end

    test "a sent round renders as a card under its sender, and a plain message as the plain bubble", %{
      task: task,
      roles_map: roles_map,
      plan: plan,
      scope: scope
    } do
      [comment] = Pipeline.list_plan_comments(scope, task)
      message = Rail.Pipeline.Schemas.PlanComment.calculate_message([comment], Pipeline.read_design(task, pages: false))
      tag = "[human:#{scope.user.id}]"
      Pipeline.append_run_events(plan.id, nil, Enum.map(String.split(message, "\n"), &"#{tag} #{&1}"))
      Pipeline.append_run_events(plan.id, nil, ["[rail] ok", "#{tag} 1 comment on the design, I think."])

      html =
        render_component(RunConversation,
          id: "conv",
          task: task,
          runs: [plan],
          roles_map: roles_map,
          current_scope: scope
        )

      doc = Floki.parse_fragment!(html)

      assert [card] = Floki.find(doc, "[data-qa='plan_comment_card']")
      assert Floki.text(card) =~ "You"
      assert Floki.text(card) =~ "1 comment on the design"
      assert Floki.text(card) =~ "Lanes by what they wait on"
      assert Floki.text(card) =~ "#group-by-project"
      assert Floki.text(card) =~ "Turn this on by default."
      assert [bubble] = Floki.find(doc, "[data-qa='human-bubble']")
      assert Floki.text(bubble) =~ "1 comment on the design, I think."
    end

    test "where the Plan chat cannot take a message the rows stay with Remove, Send goes, and the banner says why", %{
      task: task,
      roles_map: roles_map,
      plan: plan,
      scope: scope
    } do
      Repo.update_all(from(r in Rail.Pipeline.Schemas.Run, where: r.id == ^plan.id), set: [conversation_id: nil])
      plan = Repo.reload!(plan)

      html =
        render_component(RunConversation,
          id: "conv",
          task: task,
          runs: [plan],
          roles_map: roles_map,
          current_scope: scope
        )

      assert html =~ "Turn this on by default."
      assert html =~ "remove-plan-comment-"
      refute html =~ "send-plan-comments"
      assert html =~ ~s(id="unavailable-banner")
      assert html =~ "has not started a conversation"
    end
  end
end
