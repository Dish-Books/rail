defmodule Rail.Tools.Actions.ListSandboxUsageTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    insert = fn attrs ->
      Repo.insert!(
        struct(
          %OsProcess{
            run_id: run.id,
            task_id: run.task_id,
            stream_path: "/dev/null",
            status: :running,
            started_at: DateTime.utc_now(),
            reserved_cpus: 2,
            reserved_memory_gb: 4
          },
          attrs
        )
      )
    end

    %{insert: insert}
  end

  test "reads what each running container is using: CPUs over the last reading, memory less its page cache", %{
    insert: insert
  } do
    %OsProcess{id: busy_id} = insert.(%{runtime: :docker, container_id: "c-busy"})
    _beside_rail = insert.(%{runtime: :local, os_pid: 4242})
    _unreachable = insert.(%{runtime: :docker, container_id: "c-gone"})

    Req.Test.stub(Docker, fn
      %{request_path: "/containers/c-busy/stats"} = conn ->
        Req.Test.json(conn, %{
          "cpu_stats" => %{"cpu_usage" => %{"total_usage" => 1_400}, "system_cpu_usage" => 10_000, "online_cpus" => 16},
          "precpu_stats" => %{"cpu_usage" => %{"total_usage" => 700}, "system_cpu_usage" => 2_000},
          "memory_stats" => %{"usage" => 3 * 1024 ** 3, "stats" => %{"inactive_file" => div(1024 ** 3, 10)}}
        })

      %{request_path: "/containers/c-gone/stats"} = conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such container"})
    end)

    assert %{^busy_id => %{cpus: 1.4, memory_gb: 2.9}} = usage = Tools.list_sandbox_usage()
    assert map_size(usage) == 1
  end
end
