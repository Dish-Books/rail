defmodule Rail.Tools.Actions.CreateSandboxHostTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost

  test "saves an admin's host with an ed25519 key pair made for it and no trusted host key yet" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    assert {:ok,
            %SandboxHost{
              name: "build-05",
              ssh_address: "rail@10.0.4.15",
              host_key_fingerprint: nil,
              public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5" <> _key = public_key
            } = host} =
             Tools.create_sandbox_host(user_scope(admin: true), %{name: "build-05", ssh_address: "rail@10.0.4.15"})

    assert [{{{:ECPoint, public}, _curve}, [comment: ~c"rail@build-05"]}] = :ssh_file.decode(public_key, :openssh_key)

    stored = Repo.get!(SandboxHost, host.id)

    assert [{{:ECPrivateKey, _version, _seed, _curve, ^public, _params}, _attrs} | _public] =
             :ssh_file.decode(stored.private_key, :openssh_key_v1)

    assert_receive :sandboxes_changed
  end

  test "refuses a second live host of the same name, and frees the name once that host is removed" do
    scope = system_scope()
    {:ok, host} = Tools.create_sandbox_host(scope, %{name: "build-06", ssh_address: "rail@10.0.4.16"})

    assert {:error, changeset} = Tools.create_sandbox_host(scope, %{name: "build-06", ssh_address: "rail@10.0.4.17"})
    assert %{name: ["has already been taken"]} = errors_on(changeset)

    {:ok, _removed} = Tools.remove_sandbox_host(scope, host)

    assert {:ok, %SandboxHost{name: "build-06"}} =
             Tools.create_sandbox_host(scope, %{name: "build-06", ssh_address: "rail@10.0.4.17"})
  end

  test "is admin only" do
    assert {:error, :not_authorized} =
             Tools.create_sandbox_host(user_scope(), %{name: "build-05", ssh_address: "rail@10.0.4.15"})
  end
end
