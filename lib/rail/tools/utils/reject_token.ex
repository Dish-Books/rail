defmodule Rail.Tools.Utils.RejectToken do
  @moduledoc false

  import Rail.Tools.Utils.AnnounceLostSession

  alias Rail.Repo
  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend

  @doc """
  Records that Claude refused the backend's token, so nothing more is started
  on it, and says so once. The row is read again first: the caller's copy may
  predate a token saved since, or another run's refusal.
  """
  def reject_token(%Backend{id: id}) do
    case Repo.get(Backend, id) do
      %Backend{session_lost_at: nil, oauth_token: token} = backend when is_binary(token) ->
        lost = %{backend | session_lost_at: DateTime.utc_now()}

        rejected =
          backend
          |> Backend.usage_changeset(Map.put(Claude.probe(lost), :session_lost_at, lost.session_lost_at))
          |> Repo.update!()

        announce_lost_session(rejected)

      _gone_or_already_lost ->
        :ok
    end
  end
end
