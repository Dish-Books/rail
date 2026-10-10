defmodule Rail.Tools.HostKeys do
  @moduledoc """
  Offers a host's own ed25519 key, and trusts the first host key the host offers
  and only that one after, telling the connection each fingerprint it was offered.
  """
  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, _host, _port, _algorithm, options) do
    %{trusted: trusted, notify: notify} = Map.new(options[:key_cb_private])
    fingerprint = to_string(:ssh.hostkey_fingerprint(:sha256, key))
    send(notify, {:host_key_offered, fingerprint})

    cond do
      is_nil(trusted) -> true
      fingerprint == trusted -> true
      true -> {:error, :host_key_changed}
    end
  end

  @impl true
  def user_key(:"ssh-ed25519", options), do: {:ok, options[:key_cb_private][:key]}
  def user_key(_algorithm, _options), do: {:error, :not_ed25519}

  # The connection stores the fingerprint itself, so nothing is written to known_hosts.
  @impl true
  def add_host_key(_host, _port, _key, _options), do: :ok
end
