defmodule Rail.Support.Utils.IdentifyIntercomWorkspace do
  @moduledoc false

  alias Rail.Intercom
  alias Rail.Support.Schemas.IntercomWorkspace

  @doc """
  Asks Intercom whose token a changeset carries when the token changed, and puts the app id it answers with.
  Returns `{:ok, changeset}` or `{:error, changeset}`.
  """
  def identify_intercom_workspace(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  def identify_intercom_workspace(%Ecto.Changeset{changes: %{access_token: token}} = changeset) do
    case Intercom.me(token) do
      {:ok, identity} ->
        {:ok, IntercomWorkspace.identity_changeset(changeset, identity)}

      {:error, _reason} ->
        {:error, Ecto.Changeset.add_error(changeset, :access_token, "Intercom did not accept this token")}
    end
  end

  def identify_intercom_workspace(%Ecto.Changeset{} = changeset), do: {:ok, changeset}
end
