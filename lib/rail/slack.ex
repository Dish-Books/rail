defmodule Rail.Slack do
  @moduledoc false

  alias Rail.Slack.Client

  defdelegate auth_test(workspace), to: Client
  defdelegate list_channels(workspace), to: Client
  defdelegate replies(workspace, channel, thread_ts), to: Client
  defdelegate history(workspace, channel, oldest), to: Client
  defdelegate user_info(workspace, user_id), to: Client
  defdelegate channel_info(workspace, channel), to: Client
  defdelegate permalink(workspace, channel, ts), to: Client
  defdelegate open_connection(workspace), to: Client
  defdelegate download_file(workspace, url), to: Client
  defdelegate post_message(user_token, channel, thread_ts, text), to: Client
  defdelegate post_channel_message(workspace, channel, text), to: Client
  defdelegate authorize_url(opts \\ []), to: Client
  defdelegate exchange_code(code), to: Client
end
