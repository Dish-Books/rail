defmodule Rail.Intercom do
  @moduledoc false

  alias Rail.Intercom.Client

  defdelegate me(token), to: Client
  defdelegate list_conversations(workspace, starting_after), to: Client
  defdelegate get_conversation(workspace, external_id), to: Client
  defdelegate reply(token, external_id, admin_id, body), to: Client
  defdelegate download_file(workspace, url), to: Client
  defdelegate authorize_url(workspace, state), to: Client
  defdelegate exchange_code(workspace, code), to: Client
end
