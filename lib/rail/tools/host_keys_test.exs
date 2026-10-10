defmodule Rail.Tools.HostKeysTest do
  use ExUnit.Case, async: true

  alias Rail.Tools.HostKeys

  setup do
    {:ECPrivateKey, _version, _private, curve, public, _params} = key = :public_key.generate_key({:namedCurve, :ed25519})
    host_key = {{:ECPoint, public}, curve}
    %{key: key, host_key: host_key, fingerprint: to_string(:ssh.hostkey_fingerprint(:sha256, host_key))}
  end

  test "trusts any key from a host with none trusted, and says which it was offered", %{
    host_key: host_key,
    fingerprint: fingerprint
  } do
    options = [key_cb_private: [key: nil, trusted: nil, notify: self()]]

    assert HostKeys.is_host_key(host_key, ~c"10.0.4.12", 22, :"ssh-ed25519", options)
    assert_received {:host_key_offered, ^fingerprint}
  end

  test "once one is trusted, accepts only that one", %{host_key: host_key, fingerprint: fingerprint} do
    assert HostKeys.is_host_key(host_key, ~c"10.0.4.12", 22, :"ssh-ed25519",
             key_cb_private: [key: nil, trusted: fingerprint, notify: self()]
           )

    assert {:error, :host_key_changed} =
             HostKeys.is_host_key(host_key, ~c"10.0.4.12", 22, :"ssh-ed25519",
               key_cb_private: [key: nil, trusted: "SHA256:another", notify: self()]
             )
  end

  test "offers the host's own ed25519 key and nothing else, and writes no known_hosts", %{key: key} do
    options = [key_cb_private: [key: key, trusted: nil, notify: self()]]

    assert {:ok, ^key} = HostKeys.user_key(:"ssh-ed25519", options)
    assert {:error, :not_ed25519} = HostKeys.user_key(:"ssh-rsa", options)
    assert :ok = HostKeys.add_host_key(~c"10.0.4.12", 22, key, options)
  end
end
