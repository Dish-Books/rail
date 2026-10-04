defmodule Rail.Triage.Utils.CanLinkIssue do
  @moduledoc false

  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Triage.Schemas.Thread

  @doc """
  Whether `text` may go out in `thread`: a reply that links its issue is refused in an external channel.
  Checked on what the person submitted, before anything is claimed or created. Needs the channel preloaded.
  """
  def can_link_issue(%Thread{slack_channel: %SlackChannel{external: true}}, text) when is_binary(text) do
    if String.contains?(text, "{issue link}"), do: {:error, :external_issue_link}, else: :ok
  end

  def can_link_issue(%Thread{slack_channel: %SlackChannel{}}, _text), do: :ok
end
