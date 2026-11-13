defmodule Rail.Mcp.Actions.ValidateAuthorizeRequest do
  @moduledoc false

  import Rail.Mcp.Utils.ValidateAuthorization

  @doc """
  Checks a consent request, its `response_type` included, without issuing a code. Returns `{:ok, client}` for the
  consent page, or the OAuth error it earns.
  """
  def validate_authorize_request(%{} = params) do
    with {:ok, client} <- validate_authorization(params) do
      if params["response_type"] == "code", do: {:ok, client}, else: {:error, :unsupported_response_type}
    end
  end
end
