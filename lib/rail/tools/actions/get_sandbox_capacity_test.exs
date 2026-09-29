defmodule Rail.Tools.Actions.GetSandboxCapacityTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.LocalCapacity

  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: "rol_test_seed_engineer",
        status: :running,
        started_at: DateTime.utc_now()
      })

    for {status, cpus, memory_gb} <- [
          {:running, 2, 4},
          {:starting, 1, 2},
          {:waiting_for_resources, 1, 2},
          {:finished, 3, 3}
        ] do
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/dev/null",
        status: status,
        started_at: DateTime.utc_now(),
        reserved_cpus: cpus,
        reserved_memory_gb: memory_gb
      })
    end

    :ok
  end

  test "reserves what is starting or running, and nothing that waits or has ended" do
    assert {:ok, %{cpus: 4, memory_gb: 8, reserved_cpus: 3, reserved_memory_gb: 6}} = Tools.get_sandbox_capacity()
  end

  test "is the machine Rail runs on, read now, where nothing fixes it" do
    stub_sandbox_config(local_cpus: nil, local_memory_gb: nil, headroom_cpus: 1, headroom_memory_gb: 1)
    {cpus, memory_gb} = local_capacity()
    free_cpus = cpus - 1
    free_memory_gb = memory_gb - 1

    assert {:ok, %{cpus: ^free_cpus, memory_gb: ^free_memory_gb}} = Tools.get_sandbox_capacity()
  end

  describe "in Docker" do
    setup do
      stub_sandbox_config(runtime: :docker, headroom_cpus: 2, headroom_memory_gb: 8)
    end

    test "is what the machine has, less the headroom kept for Rail, in whole GB" do
      Req.Test.expect(Docker, &Req.Test.json(&1, %{"NCPU" => 16, "MemTotal" => 64 * 1024 ** 3 + 12_345}))

      assert {:ok, %{cpus: 14, memory_gb: 56, reserved_cpus: 3, reserved_memory_gb: 6}} = Tools.get_sandbox_capacity()
    end

    test "is not known when Docker cannot be asked" do
      Req.Test.expect(Docker, &Req.Test.transport_error(&1, :enoent))

      assert {:error, %Req.TransportError{reason: :enoent}} = Tools.get_sandbox_capacity()
    end
  end
end
