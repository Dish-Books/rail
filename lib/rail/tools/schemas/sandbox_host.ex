defmodule Rail.Tools.Schemas.SandboxHost do
  @moduledoc """
  An extra machine running Docker that Rail reaches over SSH. Rail generates its
  key pair and trusts the first host key it is offered, so neither is cast from attrs.
  """
  use Rail.Schema

  alias Rail.Types.EncryptedBinary

  @address ~r/^(?<user>[A-Za-z0-9._-]+)@(?<host>[A-Za-z0-9.-]+)(?::(?<port>\d+))?$/

  @primary_key {:id, UXID, autogenerate: true, prefix: "hst"}
  schema "sandbox_hosts" do
    field :name, :string
    field :ssh_address, :string
    field :private_key, EncryptedBinary, redact: true
    field :public_key, :string
    field :host_key_fingerprint, :string
    field :removed_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:name, :ssh_address])
    |> update_change(:name, &String.trim/1)
    |> update_change(:ssh_address, &String.trim/1)
    |> validate_required([:name, :ssh_address])
    |> validate_length(:name, max: 80)
    |> validate_format(:ssh_address, @address, message: "must be user@host, with :port when it isn't 22")
    |> validate_change(:ssh_address, fn :ssh_address, address ->
      with %{"port" => "" <> port} when port != "" <- Regex.named_captures(@address, address),
           false <- String.to_integer(port) in 1..65_535 do
        [ssh_address: "has a port out of range"]
      else
        _no_port_or_in_range -> []
      end
    end)
    |> unique_constraint(:name, name: :sandbox_hosts_live_name_index)
  end

  def key_pair_changeset(host, private_key, public_key) do
    change(host, private_key: private_key, public_key: public_key)
  end

  @doc "The address split into `{user, host, port}`, port 22 when it names none."
  def ssh_target(%__MODULE__{ssh_address: address}) do
    %{"user" => user, "host" => host, "port" => port} = Regex.named_captures(@address, address)
    {user, host, if(port == "", do: 22, else: String.to_integer(port))}
  end
end
