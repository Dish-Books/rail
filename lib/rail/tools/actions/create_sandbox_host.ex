defmodule Rail.Tools.Actions.CreateSandboxHost do
  @moduledoc false

  import Rail.Tools.Utils.EnsureHostConnections

  alias Rail.Repo
  alias Rail.Tools.Schemas.SandboxHost

  # OTP's ssh_file writes ed25519 as an ECPrivateKey on the Ed25519 curve, and
  # OpenSSH expects the seed followed by the public key in its private field.
  @ed25519 {:namedCurve, {1, 3, 101, 112}}

  @doc """
  Saves a host with an ed25519 key pair generated for it, whose public half the
  admin adds to the host, and starts its connection.
  """
  def create_sandbox_host(_scope, attrs) do
    changeset = SandboxHost.changeset(%SandboxHost{}, attrs)
    comment = "rail@#{Ecto.Changeset.get_field(changeset, :name)}"
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    private_key = {:ECPrivateKey, 1, private <> public, @ed25519, public, :asn1_NOVALUE}

    with {:ok, host} <-
           changeset
           |> SandboxHost.key_pair_changeset(
             :ssh_file.encode([{[{private_key, comment}], []}], :openssh_key_v1),
             String.trim(:ssh_file.encode([{{{:ECPoint, public}, @ed25519}, [comment: comment]}], :openssh_key))
           )
           |> Repo.insert() do
      _connections = ensure_host_connections()
      Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
      {:ok, host}
    end
  end
end
