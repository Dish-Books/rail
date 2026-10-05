defmodule Rail.Tools.Actions.SetBackendToken do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend

  @doc """
  Replaces the token a Claude backend is signed in by, the one `claude setup-token`
  prints, or removes it with nil or a blank. The backend reads as ready or signed
  out straight away, without waiting on the next probe.
  """
  def set_backend_token(_scope, %Backend{} = backend, token) do
    token = if is_binary(token) and String.trim(token) != "", do: String.trim(token)

    if is_binary(token) and token =~ ~r/\s/ do
      {:error, :invalid_token}
    else
      tokened = backend |> Backend.token_changeset(token) |> Repo.update!()
      tokened |> Backend.usage_changeset(Claude.probe(tokened)) |> Repo.update()
    end
  end
end
