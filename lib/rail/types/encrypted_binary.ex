defmodule Rail.Types.EncryptedBinary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: Rail.Vault
end
