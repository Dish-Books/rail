defmodule Rail.Tools.Utils.RejectToken do
  @moduledoc false

  import Rail.Tools.Utils.AnnounceLostSession

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  @doc """
  Records that Claude refused the backend's sign-in, so nothing more is started
  on it until it is signed in again, and says so once. The row is read again
  first: the caller's copy may predate a sign-in since, or another run's refusal.
  """
  def reject_token(%Backend{id: id}) do
    case Repo.get(Backend, id) do
      %Backend{session_lost_at: nil} = backend ->
        rejected =
          backend
          |> Backend.usage_changeset(%{
            status: :signed_out,
            session_lost_at: DateTime.utc_now(),
            unavailable_reason: "Claude refused this backend's sign-in. Sign it in again."
          })
          |> Repo.update!()

        announce_lost_session(rejected)

      _gone_or_already_lost ->
        :ok
    end
  end
end
