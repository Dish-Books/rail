defmodule Rail.Tools.Actions.ListSandboxHosts do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.SandboxHost

  @doc "The extra hosts not removed, oldest first."
  def list_sandbox_hosts do
    Repo.all(from h in SandboxHost, where: is_nil(h.removed_at), order_by: [asc: h.inserted_at, asc: h.id])
  end
end
