defmodule Rail.Tools.Schemas.SandboxHostTest do
  use Rail.DataCase, async: true

  alias Rail.Tools.Schemas.SandboxHost

  test "needs a name and an SSH address" do
    changeset = SandboxHost.changeset(%SandboxHost{}, %{name: " ", ssh_address: ""})
    assert %{name: ["can't be blank"], ssh_address: ["can't be blank"]} = errors_on(changeset)
  end

  test "takes an address as user@host with an optional port, and nothing else" do
    assert SandboxHost.changeset(%SandboxHost{}, %{name: "build-02", ssh_address: " rail@10.0.4.12:2222 "}).valid?

    for address <- ["10.0.4.12", "rail@", "rail@10.0.4.12:", "rail@10.0.4.12:22x", "ssh://rail@10.0.4.12"] do
      changeset = SandboxHost.changeset(%SandboxHost{}, %{name: "build-02", ssh_address: address})
      assert %{ssh_address: ["must be user@host, with :port when it isn't 22"]} = errors_on(changeset)
    end

    for address <- ["rail@10.0.4.12:0", "rail@10.0.4.12:65536"] do
      changeset = SandboxHost.changeset(%SandboxHost{}, %{name: "build-02", ssh_address: address})
      assert %{ssh_address: ["has a port out of range"]} = errors_on(changeset)
    end
  end

  test "splits the address, with port 22 when it names none" do
    assert {"rail", "10.0.4.12", 22} = SandboxHost.ssh_target(%SandboxHost{ssh_address: "rail@10.0.4.12"})

    assert {"deploy", "build-02.lan", 2222} =
             SandboxHost.ssh_target(%SandboxHost{ssh_address: "deploy@build-02.lan:2222"})
  end

  test "never takes the key pair or the trusted host key from attrs" do
    changeset =
      SandboxHost.changeset(%SandboxHost{}, %{
        name: "build-02",
        ssh_address: "rail@10.0.4.12",
        private_key: "stolen",
        public_key: "ssh-ed25519 AAAA",
        host_key_fingerprint: "SHA256:forged"
      })

    assert changeset.changes == %{name: "build-02", ssh_address: "rail@10.0.4.12"}
  end
end
