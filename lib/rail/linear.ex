defmodule Rail.Linear do
  @moduledoc false

  alias Rail.Linear.Client

  defdelegate authorize_url(opts \\ []), to: Client
  defdelegate exchange_code(code, opts \\ []), to: Client
  defdelegate refresh_token(refresh_token, opts \\ []), to: Client
  defdelegate viewer(access_token, opts \\ []), to: Client
end
