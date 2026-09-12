defmodule Rail.Roles.Actions.RecentFinishedRunsTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.RunRecord
  alias Rail.Runs
  alias Rail.Scope

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Recent Runs Project",
        github_repo: "org/recent-runs",
        github_installation_id: 4501,
        linear_team_id: "team_recent_runs",
        linear_team_key: "RCR",
        default_branch: "main",
        clone_path: "/tmp/repos/recent-runs"
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        name: "Engineer",
        stage: :engineer,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert engineer."
      })

    %{project: project, role: role}
  end

  test "extracts recent finished runs ordered descending with transcript digest", %{role: role} do
    scope = Scope.for_system()

    now = DateTime.utc_now()

    {:ok, run1} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_01",
        status: :finished,
        started_at: DateTime.shift(now, minute: -1),
        completed_at: DateTime.shift(now, second: -40),
        exit_code: 0
      })

    Runs.append_run_event(run1, "Transcript output for run 1")

    {:ok, run2} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_02",
        status: :finished,
        started_at: DateTime.shift(now, second: -30),
        completed_at: DateTime.shift(now, second: -10),
        exit_code: 1,
        error: "Compilation failed"
      })

    Runs.append_run_event(run2, "Transcript output for run 2")

    tasks = [
      %{id: "tsk_01", title: "Implement feature A"},
      %{id: "tsk_02", title: "Fix bug B"}
    ]

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks)

    assert [
             %RunRecord{
               task_id: "tsk_02",
               title: "Fix bug B",
               stage: "Engineer",
               status: :finished,
               exit_code: 1,
               duration: 20,
               error: "Compilation failed",
               transcript_text: "Transcript output for run 2"
             },
             %RunRecord{
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

  test "falls back to run_events when output is blank", %{role: role} do
    scope = Scope.for_system()

    {:ok, rr} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_events",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    _run_event = Runs.append_run_event(rr.id, "Line one from events")
    _run_event = Runs.append_run_event(rr.id, "Line two from events")

    assert [%RunRecord{transcript_text: "Line one from events\nLine two from events"}] =
             Roles.recent_finished_runs(scope, role.id)
  end

  test "supports custom transcript_reader callback", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_custom",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Ignored output")

    custom_reader = fn rr -> "Custom transcript for #{rr.task_id}" end

    assert [%RunRecord{transcript_text: "Custom transcript for tsk_custom"}] =
             Roles.recent_finished_runs(scope, role.id, transcript_reader: custom_reader)
  end

  test "skips runs with blank transcripts and ignores in-flight runs", %{role: role} do
    scope = Scope.for_system()

    # blank output and no events
    {:ok, _run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_blank",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    # running run
    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_live",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Text")

    assert Roles.recent_finished_runs(scope, role.id) == []
  end

  test "applies head and tail truncation when transcript exceeds max_chars", %{role: role} do
    scope = Scope.for_system()

    long_text = String.duplicate("A", 100) <> String.duplicate("B", 800) <> String.duplicate("C", 100)

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_trunc",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, long_text)

    [record] = Roles.recent_finished_runs(scope, role.id, max_chars: 250, head_chars: 50, tail_chars: 50)
    assert record.transcript_text =~ "[... 900 characters truncated ...]"
  end

  test "resolves title from tasks map and falls back when missing", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_mapped",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_unmapped",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    tasks_map = %{"tsk_mapped" => %{title: "Mapped Title"}}

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks_map)
    assert Enum.any?(records, &(&1.title == "Mapped Title"))
    assert Enum.any?(records, &(&1.title == "Task tsk_unmapped"))
  end

  test "limits returned records to specified limit", %{role: role} do
    scope = Scope.for_system()

    for i <- 1..6 do
      {:ok, run} =
        Runs.create_run(%{
          role_id: role.id,
          task_id: "tsk_#{i}",
          status: :finished,
          started_at: DateTime.utc_now()
        })

      Runs.append_run_event(run, "Output #{i}")
    end

    records = Roles.recent_finished_runs(scope, role.id, limit: 3)
    assert length(records) == 3
  end

  test "returns not authorized for unauthenticated scope", %{role: role} do
    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_unauthorized",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    assert {:error, :not_authorized} = Roles.recent_finished_runs(nil, role.id)
  end

  test "resolves title from list of string maps and handles unmatched task", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_str_key",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_unmatched_list",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    tasks = [
      %{"id" => "tsk_str_key", "title" => "String Key Title"},
      %{"id" => "tsk_other", "title" => "Other Title"}
    ]

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks)
    assert Enum.any?(records, &(&1.title == "String Key Title"))
    assert Enum.any?(records, &(&1.title == "Task tsk_unmatched_list"))
  end

  test "resolves title from map with string title or direct binary title", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_nested_map",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_binary_map",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    tasks = %{
      "tsk_nested_map" => %{"title" => "Nested Map Title"},
      "tsk_binary_map" => "Direct Binary Title"
    }

    records = Roles.recent_finished_runs(scope, role.id, tasks: tasks)
    assert Enum.any?(records, &(&1.title == "Nested Map Title"))
    assert Enum.any?(records, &(&1.title == "Direct Binary Title"))
  end

  test "supports explicit stage opt and falls back to Unknown when role is missing", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_explicit_stage",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    assert [%RunRecord{stage: "Custom Stage"}] =
             Roles.recent_finished_runs(scope, role.id, stage: "Custom Stage")

    fake_role_id = "rol_000000000000000000000000"

    {:ok, run} =
      Runs.create_run(%{
        role_id: fake_role_id,
        task_id: "tsk_no_role",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    assert [%RunRecord{stage: "Unknown"}] =
             Roles.recent_finished_runs(scope, fake_role_id)
  end

  test "returns nil duration when run has missing timestamp", %{role: role} do
    scope = Scope.for_system()

    {:ok, run} =
      Runs.create_run(%{
        role_id: role.id,
        task_id: "tsk_no_completed_at",
        status: :finished,
        completed_at: nil,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Out")

    assert [%RunRecord{duration: nil}] =
             Roles.recent_finished_runs(scope, role.id)
  end
end
