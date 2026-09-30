defmodule Rail.Pipeline.Schemas.RunTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  test "changeset/2 with valid attributes" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")
    now = DateTime.utc_now()

    attrs = %{
      task_id: task_id,
      role_id: role_id,
      status: :running,
      started_at: now,
      conversation_id: "conv-123",
      exit_code: 0,
      usage: %{input_tokens: 100, output_tokens: 50}
    }

    changeset = Run.changeset(%Run{}, attrs)
    assert changeset.valid?

    assert get_change(changeset, :task_id) == task_id
    assert get_change(changeset, :role_id) == role_id
    assert get_change(changeset, :status) == :running
    assert get_change(changeset, :conversation_id) == "conv-123"

    usage_changeset = get_change(changeset, :usage)
    assert %Run.Usage{input_tokens: 100, output_tokens: 50} = apply_changes(usage_changeset)
  end

  test "changeset/2 validates required fields" do
    changeset = Run.changeset(%Run{}, %{})
    refute changeset.valid?

    errors = errors_on(changeset)
    assert "can't be blank" in errors.task_id
    assert "can't be blank" in errors.role_id
    assert "can't be blank" in errors.status
    assert "can't be blank" in errors.started_at
  end

  test "changeset/2 validates status enum" do
    changeset = Run.changeset(%Run{}, %{status: "invalid_status"})
    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).status
  end

  test "changeset/2 refuses to move a run to another conversation" do
    changeset = Run.changeset(%Run{conversation_id: "sess-1"}, %{conversation_id: "sess-2"})

    assert "is already set and cannot be changed" in errors_on(changeset).conversation_id
  end

  # A run waiting in line for its sandbox is in flight: nothing may approve, rebase or
  # clean up under it, and a message typed now waits for it.
  test "running?/1 is true for a run that is executing or waiting for resources" do
    assert Run.running?(%Run{status: :running})
    assert Run.running?(%Run{status: :waiting_for_resources})
    refute Run.running?(%Run{status: :finished})
  end

  test "running?/1 is false for anything that is not a run" do
    refute Run.running?(nil)
  end

  test "state/1 reads what a run says about itself" do
    assert Run.state(%Run{status: :running}) == :running
    assert Run.state(%Run{status: :blocked_on_input}) == :blocked
    assert Run.state(%Run{status: :finished, stage_outcome: :done}) == :done
    assert Run.state(%Run{status: :finished, error: "It went wrong"}) == :failed
    assert Run.state(%Run{status: :finished}) == :stopped
    assert Run.state(nil) == :queued
    assert Run.state(%Run{status: :waiting_for_resources}) == :waiting
  end

  test "statuses/0 returns all allowed statuses" do
    statuses = Run.statuses()
    assert :starting in statuses
    assert :running in statuses
    assert :finished in statuses
    assert :adopted_dead in statuses
    assert :blocked_on_input in statuses
  end

  test "insert and retrieve run with embeds" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")
    now = DateTime.utc_now()

    {:ok, run} =
      %Run{}
      |> Run.changeset(%{
        task_id: task_id,
        role_id: role_id,
        status: :starting,
        started_at: now,
        usage: %{input_tokens: 120, output_tokens: 40}
      })
      |> Repo.insert()

    assert String.starts_with?(run.id, "run_")
    assert run.usage.input_tokens == 120
    assert run.usage.output_tokens == 40
  end

  test "has_started?/1 and can_chat?/1 logic" do
    unstarted = %Run{started_at: nil, conversation_id: nil}
    refute Run.has_started?(unstarted)
    refute Run.can_chat?(unstarted)

    started_no_conv = %Run{started_at: DateTime.utc_now(), conversation_id: nil}
    assert Run.has_started?(started_no_conv)
    refute Run.can_chat?(started_no_conv)

    started_empty_conv = %Run{started_at: DateTime.utc_now(), conversation_id: "  "}
    assert Run.has_started?(started_empty_conv)
    refute Run.can_chat?(started_empty_conv)

    started_with_conv = %Run{started_at: DateTime.utc_now(), conversation_id: "sess-123"}
    assert Run.has_started?(started_with_conv)
    assert Run.can_chat?(started_with_conv)

    # A conversation is not a start: a run that never ran cannot be resumed.
    conv_without_start = %Run{started_at: nil, conversation_id: "sess-456"}
    refute Run.has_started?(conv_without_start)
    refute Run.can_chat?(conv_without_start)

    # A working run takes a message to queue before it has recorded its conversation.
    working_no_conv = %Run{status: :running, started_at: DateTime.utc_now(), conversation_id: nil}
    assert Run.can_chat?(working_no_conv)

    refute Run.has_started?(nil)
    refute Run.can_chat?(nil)
  end

  test "usage rejects negative token counts" do
    changeset =
      Run.changeset(%Run{}, %{
        usage: %{
          "input_tokens" => -1,
          "output_tokens" => -1,
          "cache_read_input_tokens" => -1,
          "cache_creation_input_tokens" => -1
        }
      })

    refute changeset.valid?

    assert %{
             input_tokens: ["must be greater than or equal to 0"],
             output_tokens: ["must be greater than or equal to 0"],
             cache_read_input_tokens: ["must be greater than or equal to 0"],
             cache_creation_input_tokens: ["must be greater than or equal to 0"]
           } = errors_on(changeset).usage
  end

  test "usage accumulates rather than replacing what a run already spent" do
    run = %Run{usage: %Run.Usage{input_tokens: 100, output_tokens: 40}}

    changeset = Run.changeset(run, %{usage: %Run.Usage{input_tokens: 10, output_tokens: 5}})

    assert %Run.Usage{input_tokens: 110, output_tokens: 45} = apply_changes(changeset).usage
  end

  test "the first usage a run records is what it spent" do
    changeset = Run.changeset(%Run{}, %{usage: %Run.Usage{input_tokens: 10}})

    assert %Run.Usage{input_tokens: 10} = apply_changes(changeset).usage
  end

  test "usage/1 abbreviates the token count, and says nothing when there is none" do
    assert Run.usage(%Run{usage: %Run.Usage{input_tokens: 500}}) == "500 tokens"
    assert Run.usage(%Run{usage: %Run.Usage{input_tokens: 1_500}}) == "1.5K tokens"
    assert Run.usage(%Run{usage: %Run.Usage{input_tokens: 2_500_000}}) == "2.5M tokens"

    counted_by_kind = %Run.Usage{
      input_tokens: 100,
      output_tokens: 50,
      cache_read_input_tokens: 20,
      cache_creation_input_tokens: 10
    }

    assert Run.usage(%Run{usage: counted_by_kind}) == "180 tokens"

    assert is_nil(Run.usage(%Run{usage: nil}))
    assert is_nil(Run.usage(%Run{usage: %Run.Usage{}}))
  end

  test "a run has been waiting since it stopped" do
    stopped = ~U[2026-01-01 10:00:00Z]

    assert Run.waiting_since(%Run{completed_at: stopped}) == stopped
  end

  test "a run that has not recorded stopping has been waiting since it was last touched" do
    touched = ~U[2026-01-01 09:00:00Z]
    created = ~U[2026-01-01 08:00:00Z]

    assert Run.waiting_since(%Run{completed_at: nil, updated_at: touched}) == touched
    assert Run.waiting_since(%Run{completed_at: nil, updated_at: nil, inserted_at: created}) == created
  end

  test "a blocked run on an unmerged task needs a human" do
    blocked = %Run{
      status: :blocked_on_input,
      role: %Role{stage: :engineer},
      task: %Task{stage: :engineer, merged_at: nil}
    }

    assert Run.needs_attention?(blocked)
  end

  test "a failed run is waiting on someone fixing it" do
    failed = %Run{
      status: :finished,
      error: "The engineer did not write commits/UPN-1.md.",
      role: %Role{stage: :engineer},
      task: %Task{stage: :engineer, merged_at: nil}
    }

    assert Run.needs_attention?(failed)
  end

  # A run that ended without concluding is resolved the same way a failed one is,
  # by a message, so it waits in the same place.
  test "a run that stopped without concluding is waiting too" do
    stopped = %Run{
      status: :finished,
      role: %Role{stage: :engineer},
      task: %Task{stage: :engineer, merged_at: nil}
    }

    assert Run.needs_attention?(stopped)
  end

  test "a failed run at a stage the task has left is not this task's problem" do
    passed_by = %Run{
      status: :finished,
      error: "It went wrong",
      role: %Role{stage: :product},
      task: %Task{stage: :engineer, merged_at: nil}
    }

    refute Run.needs_attention?(passed_by)
  end

  test "a run that is not blocked needs nothing" do
    running = %Run{status: :running, role: %Role{stage: :engineer}, task: %Task{stage: :engineer, merged_at: nil}}
    refute Run.needs_attention?(running)
  end

  test "a recorded demo is waiting on the change being merged" do
    done = %Run{
      status: :finished,
      stage_outcome: :done,
      role: %Role{stage: :demo},
      task: %Task{stage: :demo, merged_at: nil}
    }

    assert Run.needs_attention?(done)
  end

  test "a done product run is waiting on its ticket to be approved" do
    done = %Run{
      status: :finished,
      stage_outcome: :done,
      role: %Role{stage: :product},
      task: %Task{stage: :product, merged_at: nil}
    }

    assert Run.needs_attention?(done)
  end

  test "a done design run is waiting on its design to be approved" do
    done = %Run{
      status: :finished,
      stage_outcome: :done,
      role: %Role{stage: :design},
      task: %Task{stage: :design, merged_at: nil}
    }

    assert Run.needs_attention?(done)
  end

  test "a done run of a stage the task has already left needs nothing" do
    approved = %Run{
      status: :finished,
      stage_outcome: :done,
      role: %Role{stage: :product},
      task: %Task{stage: :design, merged_at: nil}
    }

    refute Run.needs_attention?(approved)
  end

  test "a done architect run is waiting on its plan to be approved" do
    done = %Run{
      status: :finished,
      stage_outcome: :done,
      role: %Role{stage: :architect},
      task: %Task{stage: :architect, merged_at: nil}
    }

    assert Run.needs_attention?(done)
  end

  test "a done engineer run is waiting on its diff being sent to review" do
    done = %Run{
      status: :finished,
      stage_outcome: :done,
      role: %Role{stage: :engineer},
      task: %Task{stage: :engineer, merged_at: nil}
    }

    assert Run.needs_attention?(done)
  end

  test "a done run at a stage no human signs off needs nothing" do
    done = %Run{
      status: :finished,
      stage_outcome: :done,
      role: %Role{stage: :debugger},
      task: %Task{stage: :debugger, merged_at: nil}
    }

    refute Run.needs_attention?(done)
  end

  test "a merged task needs nothing, however its run ended" do
    merged_stage = %Run{
      status: :blocked_on_input,
      role: %Role{stage: :merged},
      task: %Task{stage: :merged, merged_at: nil}
    }

    refute Run.needs_attention?(merged_stage)

    merged_at = %Run{
      status: :blocked_on_input,
      role: %Role{stage: :engineer},
      task: %Task{stage: :engineer, merged_at: DateTime.utc_now()}
    }

    refute Run.needs_attention?(merged_at)
  end

  # A human who messages the engineer from a task at QA has put the engineer to work,
  # so while it works the task is not the finished QA report.
  test "a task stands where another role is working while its own stage is done" do
    qa_done = %Run{
      status: :finished,
      stage_outcome: :done,
      started_at: ~U[2026-01-01 10:00:00Z],
      role: %Role{stage: :qa}
    }

    engineer_running = %Run{status: :running, started_at: ~U[2026-01-01 09:00:00Z], role: %Role{stage: :engineer}}
    engineer_waiting = %{engineer_running | status: :waiting_for_resources}

    assert Run.standing_run(%Task{stage: :qa}, [qa_done, engineer_running]) == engineer_running
    assert Run.standing_run(%Task{stage: :qa}, [qa_done, engineer_waiting]) == engineer_waiting
  end

  test "a task whose own stage is working stands there, whatever else is working" do
    qa_running = %Run{status: :running, started_at: ~U[2026-01-01 09:00:00Z], role: %Role{stage: :qa}}
    engineer_running = %Run{status: :running, started_at: ~U[2026-01-01 10:00:00Z], role: %Role{stage: :engineer}}

    assert Run.standing_run(%Task{stage: :qa}, [engineer_running, qa_running]) == qa_running
  end

  test "with nothing working, a task stands where the latest run at its stage left it" do
    qa_retried = %Run{status: :finished, error: "boom", started_at: ~U[2026-01-01 09:00:00Z], role: %Role{stage: :qa}}

    qa_done = %Run{
      status: :finished,
      stage_outcome: :done,
      started_at: ~U[2026-01-01 10:00:00Z],
      role: %Role{stage: :qa}
    }

    engineer_done = %Run{
      status: :finished,
      stage_outcome: :done,
      started_at: ~U[2026-01-01 11:00:00Z],
      role: %Role{stage: :engineer}
    }

    assert Run.standing_run(%Task{stage: :qa}, [qa_retried, engineer_done, qa_done]) == qa_done
  end

  test "a task with no run at its stage and nothing working stands nowhere yet" do
    engineer_done = %Run{
      status: :finished,
      stage_outcome: :done,
      started_at: ~U[2026-01-01 11:00:00Z],
      role: %Role{stage: :engineer}
    }

    assert is_nil(Run.standing_run(%Task{stage: :qa}, [engineer_done]))
    assert is_nil(Run.standing_run(%Task{stage: :qa}, []))
  end

  # Such a run has no stage to name, so the task would read as " running".
  test "a working run with no role, or a role with no stage, does not say where a task stands" do
    qa_done = %Run{
      status: :finished,
      stage_outcome: :done,
      started_at: ~U[2026-01-01 09:00:00Z],
      role: %Role{stage: :qa}
    }

    role_deleted = %Run{status: :running, started_at: ~U[2026-01-01 10:00:00Z], role: nil}
    stageless = %Run{status: :running, started_at: ~U[2026-01-01 11:00:00Z], role: %Role{stage: nil}}

    assert Run.standing_run(%Task{stage: :qa}, [qa_done, role_deleted, stageless]) == qa_done
  end
end
