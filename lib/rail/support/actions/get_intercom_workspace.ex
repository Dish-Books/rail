defmodule Rail.Support.Actions.GetIntercomWorkspace do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Support.Schemas.IntercomWorkspace

  @doc """
  One workspace by its id or by Intercom's app id.
  """
  def get_intercom_workspace([{field, value}]) when field in [:id, :external_id] and is_binary(value) do
    case Repo.get_by(IntercomWorkspace, [{field, value}]) do
      %IntercomWorkspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end
end
