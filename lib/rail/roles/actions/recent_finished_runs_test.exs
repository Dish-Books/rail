defmodule Rail.Roles.Actions.RecentFinishedRunsTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Roles.RoleRunRecord
  alias Rail.Scope

  test "extracts recent finished runs ordered descending with transcript digest" do
    scope = Scope.for_system()
    role = create_test_role(stage: :engineer)

    now = DateTime.utc_now()

    run1 =
      create_test_role_run(
        role_id: role.id,
        task_id: "tsk_01",
        status: :finished,
        started_at: DateTime.shift(now, minute: -1),
        completed_at: DateTime.shift(now, second: -40),
        output: "Transcript output for run 1",
        exit_code: 0,
        pruned: false
      )

    run2 =
      create_test_role_run(
        role_id: role.id,
        task_id: "tsk_02",
        status: :finished,
        started_at: DateTime.shift(now, second: -30),
        completed_at: DateTime.shift(now, second: -10),
        output: "Transcript output for run 2",
        exit_code: 1,
        error: "Compilation failed",
        pruned: false
      )

    tasks = [
      %{id: "tsk_01", title: "Implement feature A"},
      %{id: "tsk_02", title: "Fix bug B"}
    ]

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks)

    assert [
             %RoleRunRecord{
               task_id: "tsk_02",
               title: "Fix bug B",
               stage: "Engineer",
               status: :finished,
               exit_code: 1,
               duration: 20,
               error: "Compilation failed",
               transcript_text: "Transcript output for run 2"
             },
             %RoleRunRecord{
               task_id: "tsk_01",
               title: "Implement feature A",
               stage: "Engineer",
               status: :finished,
               exit_code: 0,
               duration: 20,
               transcript_text: "Transcript output for run 1"
             }
           ] = records

    assert run1.id != run2.id
  end

  test "falls back to run_events when output is blank" do
    scope = Scope.for_system()
    role = create_test_role()

    rr =
      create_test_role_run(
        role_id: role.id,
        task_id: "tsk_events",
        status: :finished,
        output: nil
      )

    create_test_run_event(role_run_id: rr.id, seq: 1, line: "Line one from events")
    create_test_run_event(role_run_id: rr.id, seq: 2, line: "Line two from events")

    assert [%RoleRunRecord{transcript_text: "Line one from events\nLine two from events"}] =
             Roles.recent_finished_runs(scope, role.id)
  end

  test "supports custom transcript_reader callback" do
    scope = Scope.for_system()
    role = create_test_role()

    create_test_role_run(
      role_id: role.id,
      task_id: "tsk_custom",
      status: :finished,
      output: "Ignored output"
    )

    custom_reader = fn rr -> "Custom transcript for #{rr.task_id}" end

    assert [%RoleRunRecord{transcript_text: "Custom transcript for tsk_custom"}] =
             Roles.recent_finished_runs(scope, role.id, transcript_reader: custom_reader)
  end

  test "skips runs with blank transcripts and ignores pruned or in-flight runs" do
    scope = Scope.for_system()
    role = create_test_role()

    # blank output and no events
    create_test_role_run(role_id: role.id, task_id: "tsk_blank", status: :finished, output: "")
    # pruned run
    create_test_role_run(role_id: role.id, task_id: "tsk_pruned", status: :finished, output: "Text", pruned: true)
    # running run
    create_test_role_run(role_id: role.id, task_id: "tsk_live", status: :running, output: "Text")

    assert Roles.recent_finished_runs(scope, role.id) == []
  end

  test "applies head and tail truncation when transcript exceeds max_chars" do
    scope = Scope.for_system()
    role = create_test_role()

    long_text = String.duplicate("A", 100) <> String.duplicate("B", 800) <> String.duplicate("C", 100)

    create_test_role_run(
      role_id: role.id,
      task_id: "tsk_trunc",
      status: :finished,
      output: long_text
    )

    [record] = Roles.recent_finished_runs(scope, role.id, max_chars: 250, head_chars: 50, tail_chars: 50)
    assert record.transcript_text =~ "[... 900 characters truncated ...]"
  end

  test "resolves title from tasks map and falls back when missing" do
    scope = Scope.for_system()
    role = create_test_role()

    create_test_role_run(role_id: role.id, task_id: "tsk_mapped", status: :finished, output: "Out")
    create_test_role_run(role_id: role.id, task_id: "tsk_unmapped", status: :finished, output: "Out")

    tasks_map = %{"tsk_mapped" => %{title: "Mapped Title"}}

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks_map)
    assert Enum.any?(records, &(&1.title == "Mapped Title"))
    assert Enum.any?(records, &(&1.title == "Task tsk_unmapped"))
  end

  test "limits returned records to specified limit" do
    scope = Scope.for_system()
    role = create_test_role()

    for i <- 1..6 do
      create_test_role_run(
        role_id: role.id,
        task_id: "tsk_#{i}",
        status: :finished,
        output: "Output #{i}"
      )
    end

    records = Roles.recent_finished_runs(scope, role.id, limit: 3)
    assert length(records) == 3
  end

  test "returns empty list for unauthenticated scope" do
    role = create_test_role()
    create_test_role_run(role_id: role.id, status: :finished, output: "Out")

    assert Roles.recent_finished_runs(nil, role.id) == []
  end

  test "resolves title from list of string maps and handles unmatched task" do
    scope = Scope.for_system()
    role = create_test_role()

    create_test_role_run(role_id: role.id, task_id: "tsk_str_key", status: :finished, output: "Out")
    create_test_role_run(role_id: role.id, task_id: "tsk_unmatched_list", status: :finished, output: "Out")

    tasks = [
      %{"id" => "tsk_str_key", "title" => "String Key Title"},
      %{"id" => "tsk_other", "title" => "Other Title"}
    ]

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks)
    assert Enum.any?(records, &(&1.title == "String Key Title"))
    assert Enum.any?(records, &(&1.title == "Task tsk_unmatched_list"))
  end

  test "resolves title from map with string title or direct binary title" do
    scope = Scope.for_system()
    role = create_test_role()

    create_test_role_run(role_id: role.id, task_id: "tsk_nested_map", status: :finished, output: "Out")
    create_test_role_run(role_id: role.id, task_id: "tsk_binary_map", status: :finished, output: "Out")

    tasks = %{
      "tsk_nested_map" => %{"title" => "Nested Map Title"},
      "tsk_binary_map" => "Direct Binary Title"
    }

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks)
    assert Enum.any?(records, &(&1.title == "Nested Map Title"))
    assert Enum.any?(records, &(&1.title == "Direct Binary Title"))
  end

  test "supports explicit stage opt and falls back to Unknown when role is missing" do
    scope = Scope.for_system()
    role = create_test_role()

    create_test_role_run(role_id: role.id, task_id: "tsk_explicit_stage", status: :finished, output: "Out")

    assert [%RoleRunRecord{stage: "Custom Stage"}] =
             Roles.recent_finished_runs(scope, role.id, stage: "Custom Stage")

    fake_role_id = "rol_000000000000000000000000"
    create_test_role_run(role_id: fake_role_id, task_id: "tsk_no_role", status: :finished, output: "Out")

    assert [%RoleRunRecord{stage: "Unknown"}] =
             Roles.recent_finished_runs(scope, fake_role_id)
  end

  test "returns nil duration when role run has missing timestamp" do
    scope = Scope.for_system()
    role = create_test_role()

    create_test_role_run(
      role_id: role.id,
      task_id: "tsk_no_completed_at",
      status: :finished,
      completed_at: nil,
      output: "Out"
    )

    assert [%RoleRunRecord{duration: nil}] =
             Roles.recent_finished_runs(scope, role.id)
  end
end
