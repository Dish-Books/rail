defmodule Rail.Pipeline.Actions.AppendRunEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    %{run: run}
  end

  test "appends the lines in order against the process that wrote them", %{run: run} do
    %OsProcess{id: os_process_id} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/append_run_events.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Pipeline.append_run_events(run.id, os_process_id, ["one", "two"])

    assert [%{line: "one", os_process_id: ^os_process_id}, %{line: "two", os_process_id: ^os_process_id}] =
             Pipeline.list_run_events(run)
  end

  test "a line with no process belongs to the run alone", %{run: run} do
    Pipeline.append_run_events(run.id, nil, ["[rail] between turns"])

    assert [%{line: "[rail] between turns", os_process_id: nil}] = Pipeline.list_run_events(run)
  end

  test "broadcasts the batch on the run topic", %{run: %Run{id: run_id}} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    entries = Pipeline.append_run_events(run_id, nil, ["broadcast me"])

    assert_receive {:run_events, ^run_id, ^entries}
  end

  test "an empty batch writes and broadcasts nothing", %{run: %Run{id: run_id} = run} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert [] = Pipeline.append_run_events(run_id, nil, [])
    assert [] = Pipeline.list_run_events(run)
    refute_receive {:run_events, ^run_id, _entries}
  end
end
