defmodule RailWeb.Live.RunConversationTest do
  use Rail.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess
  alias RailWeb.Live.RunConversation

  setup %{project: project} do
    roles =
      Map.new([:architect, :engineer], fn stage ->
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
    {:ok, task} = Pipeline.create_task(issue, :product)
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    roles_map = Map.new(roles, fn {_stage, role} -> {role.id, role} end)

    %{project: project, task: task, roles: roles, roles_map: roles_map}
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

    assert html =~ "Tool activity (4 steps)"
    assert html =~ "Read ×2, Bash"
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
end
