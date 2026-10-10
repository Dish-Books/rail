defmodule Rail.Tools.Actions.RetrySandboxImageCopyTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost
  alias Rail.Tools.Workers.SyncSandboxImage

  setup do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-04", ssh_address: "rail@10.0.4.14"})
    %{host: host}
  end

  test "queues the copy again and shows it copying, and a second press queues nothing more", %{host: host} do
    {:ok, _owner} = Registry.register(Rail.Tools.HostRegistry, host.id, %{state: :connected})
    scope = user_scope(admin: true)

    assert {:ok, %SandboxHost{}} = Tools.retry_sandbox_image_copy(scope, host)
    assert {:ok, %SandboxHost{}} = Tools.retry_sandbox_image_copy(scope, host)

    assert [_one] = all_enqueued(worker: SyncSandboxImage, args: %{host_id: host.id})
    assert_received {:"$gen_cast", {:image, {:copying, 0, nil}}}
  end

  test "is admin only", %{host: host} do
    assert {:error, :not_authorized} = Tools.retry_sandbox_image_copy(user_scope(), host)
    refute_enqueued(worker: SyncSandboxImage)
  end
end
