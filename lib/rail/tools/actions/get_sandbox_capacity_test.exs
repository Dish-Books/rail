defmodule Rail.Tools.Actions.GetSandboxCapacityTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.LocalCapacity
  import Rail.Tools.Utils.UsedMemory

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

    for {status, cpus} <- [running: 2.5, starting: 0.5, waiting_for_resources: 1, finished: 3] do
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/dev/null",
        status: status,
        started_at: DateTime.utc_now(),
        reserved_cpus: cpus
      })
    end

    :ok
  end

  # Parts of CPUs that add up to whole ones read as a whole number.
  test "reserves what is starting or running, and nothing that waits or has ended" do
    assert {:ok, %{cpus: 4, reserved_cpus: 3}} = Tools.get_sandbox_capacity()
  end

  # The suite's machine is a fixed one, which has nothing in use to read.
  test "has all of the machine's memory, none of it reserved" do
    assert {:ok, %{memory_gb: 8, used_memory_gb: nil}} = Tools.get_sandbox_capacity()
  end

  test "is the machine Rail runs on, read now, where nothing fixes it" do
    stub(Rail, :local_cpus, fn -> nil end)
    stub(Rail, :sandbox_headroom_cpus, fn -> 1 end)
    {cpus, memory_gb} = local_capacity()
    free_cpus = cpus - 1
    used_memory_gb = used_memory()

    assert {:ok, %{cpus: ^free_cpus, memory_gb: ^memory_gb, used_memory_gb: in_use}} = Tools.get_sandbox_capacity()
    assert is_nil(used_memory_gb) == is_nil(in_use)
  end

  describe "in Docker" do
    setup do
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      stub(Rail, :sandbox_headroom_cpus, fn -> 2 end)
      :ok
    end

    # The shared browser's container has a share of its own, so that is never the
    # line's to hand out either. Memory is the machine's whole, with what is in use.
    test "is the machine's CPUs less the headroom kept for Rail and the browser, and all its memory in whole GB" do
      stub(Rail, :browser_cpus, fn -> 2 end)
      stub(File, :read, fn "/proc/meminfo" -> {:ok, "MemTotal: 67108864 kB\nMemAvailable: 41943040 kB\n"} end)
      Req.Test.expect(Docker, &Req.Test.json(&1, %{"NCPU" => 16, "MemTotal" => 64 * 1024 ** 3 + 12_345}))

      assert {:ok, %{cpus: 12, reserved_cpus: 3, memory_gb: 64, used_memory_gb: 24.0}} = Tools.get_sandbox_capacity()
    end

    test "is not known when Docker cannot be asked" do
      Req.Test.expect(Docker, &Req.Test.transport_error(&1, :enoent))

      assert {:error, %Req.TransportError{reason: :enoent}} = Tools.get_sandbox_capacity()
    end
  end
end
