defmodule Rail.Tools.Claude do
  @moduledoc """
  Says whether a Claude Code backend can run, as the fields a
  `Rail.Tools.Schemas.Backend` records.

  A backend is signed in by the long-lived token `claude setup-token` issues. The
  token can only run the model: it cannot read the account's name, plan or quota,
  so none of those is reported, and no CLI is started to ask.
  """

  alias Rail.Tools.Schemas.Backend

  @doc """
  Returns the usage fields for `Backend.usage_changeset/2`: ready with a token
  nothing has rejected, signed out without one, and not configured without a
  CLI to hand it to.
  """
  def probe(%Backend{} = backend) do
    executable = backend.executable_path || ""

    cond do
      not executable_file?(executable) ->
        result(:not_configured, nil, "Executable not found at '#{executable}'")

      is_nil(backend.oauth_token) ->
        result(:signed_out, nil, "No token. Run `claude setup-token` and paste the token it prints below.")

      backend.session_lost_at ->
        result(
          :signed_out,
          nil,
          "Claude rejected the token. Run `claude setup-token` again and paste the new token below."
        )

      true ->
        result(:ready, "Long-lived token", nil)
    end
  end

  # A path is only worth running if it is a regular file with an execute bit.
  defp executable_file?(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp executable_file?(_other), do: false

  defp result(status, account_label, reason) do
    %{
      name: :claude,
      status: status,
      account_label: account_label,
      account_detail: nil,
      usage: [],
      fetched_at: nil,
      unavailable_reason: reason
    }
  end
end
