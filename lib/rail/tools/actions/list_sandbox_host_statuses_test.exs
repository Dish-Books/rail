defmodule Rail.Tools.Actions.ListSandboxHostStatusesTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.HostRegistry
  alias Rail.Tools.Schemas.SandboxHost

  setup do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-02", ssh_address: "rail@10.0.4.12"})
    %{host: host}
  end

  test "under the local runtime Rail's machine comes first, and every extra host is inactive", %{host: %{id: host_id}} do
    assert [
             %{host: nil, state: :connected, image: :current, cpus: 4, cpus_total: 4, memory_gb: 8, memory_gb_total: 8},
             %{host: %SandboxHost{id: ^host_id}, state: :inactive, image: nil, cpus: nil}
           ] = Tools.list_sandbox_host_statuses()
  end

  describe "under Docker" do
    setup do
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      stub(Rail, :sandbox_headroom_cpus, fn -> 2 end)
      stub(Rail, :sandbox_headroom_memory_gb, fn -> 8 end)

      Req.Test.stub(Docker, fn conn ->
        Req.Test.json(conn, %{"NCPU" => 18, "MemTotal" => 68 * 1024 ** 3})
      end)

      :ok
    end

    test "Rail's machine shows sandboxes' share after the headroom and the browser" do
      assert [
               %{host: nil, state: :connected, cpus: 14, cpus_total: 18, memory_gb: 56, memory_gb_total: 68},
               %{host: %SandboxHost{}, state: :never_connected, image: nil, cpus: nil, trusted: nil}
             ] = Tools.list_sandbox_host_statuses()
    end

    test "Rail's machine has no figures when Docker cannot say what it has" do
      Req.Test.stub(Docker, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)

      assert [%{host: nil, cpus: nil, cpus_total: nil, memory_gb: nil, memory_gb_total: nil} | _hosts] =
               Tools.list_sandbox_host_statuses()
    end

    test "a connected host shows its totals, its image and the key Rail trusts", %{host: host} do
      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:trusted"])
      since = DateTime.utc_now()

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          state: :connected,
          since: since,
          error: nil,
          offered: "SHA256:trusted",
          machine: %{cpus: 18, memory_gb: 72},
          image: :current
        })

      assert [
               _rails_machine,
               %{
                 state: :connected,
                 since: ^since,
                 trusted: "SHA256:trusted",
                 offered: nil,
                 image: :current,
                 cpus: 16,
                 cpus_total: 18,
                 memory_gb: 64,
                 memory_gb_total: 72
               }
             ] = Tools.list_sandbox_host_statuses()
    end

    test "a host that never connected reads so, whatever its last attempt said", %{host: host} do
      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          state: :unreachable,
          since: DateTime.utc_now(),
          error: :permission_denied,
          offered: "SHA256:offered",
          machine: nil,
          image: nil
        })

      assert [_rails_machine, %{state: :never_connected, error: :permission_denied, offered: nil, image: nil}] =
               Tools.list_sandbox_host_statuses()
    end

    test "a host whose key changed shows both keys, its error and since when, and its last figures greyed",
         %{host: host} do
      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:trusted"])
      since = DateTime.shift(DateTime.utc_now(), minute: -10)

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          state: :unreachable,
          since: since,
          error: :host_key_changed,
          offered: "SHA256:offered",
          machine: %{cpus: 10, memory_gb: 40},
          image: :current
        })

      assert [
               _rails_machine,
               %{
                 state: :unreachable,
                 since: ^since,
                 error: :host_key_changed,
                 trusted: "SHA256:trusted",
                 offered: "SHA256:offered",
                 cpus: 8,
                 cpus_total: 10,
                 image: :current
               }
             ] = Tools.list_sandbox_host_statuses()
    end

    test "a host that connected before and whose connection is starting again reads as connecting", %{host: host} do
      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:trusted"])
      assert [_rails_machine, %{state: :connecting, image: nil, cpus: nil}] = Tools.list_sandbox_host_statuses()
    end
  end
end
