defmodule Rail.Triage.Utils.UpsertSlackMessage do
  @moduledoc false

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo
  alias Rail.Slack
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @restated [:author_external_id, :author_name, :from_bot, :text, :posted_at, :updated_at]

  @doc """
  Records a Slack message in `thread`, keyed by its ts, so a redelivered event
  or a backfill writes one row. A row a teammate posted through Rail is never
  overwritten. `names` caches Slack user names across calls; returns
  `{:ok, message, names}`.
  """
  def upsert_slack_message(%Thread{} = thread, %SlackWorkspace{} = workspace, %{"ts" => ts} = slack_message, names) do
    case Repo.get_by(Message, thread_id: thread.id, external_id: ts) do
      %Message{sent_by_user_id: user_id} = kept when is_binary(user_id) ->
        {:ok, kept, names}

      _new_or_ours ->
        {author, names} = author(workspace, slack_message, names)
        {text, names} = plain(workspace, raw_text(slack_message), names)

        message =
          thread
          |> Message.changeset(%{
            external_id: ts,
            author_external_id: author.id,
            author_name: author.name,
            from_bot: author.bot?,
            text: text,
            posted_at: posted_at(ts)
          })
          |> Repo.insert!(on_conflict: {:replace, @restated}, conflict_target: [:thread_id, :external_id])

        {:ok, message, names}
    end
  end

  defp author(_workspace, %{"bot_id" => bot_id} = slack_message, names) when is_binary(bot_id) do
    name = get_in(slack_message, ["bot_profile", "name"]) || slack_message["username"] || "App"
    {%{id: bot_id, name: name, bot?: true}, names}
  end

  defp author(workspace, %{"user" => user_id}, names) when is_binary(user_id) do
    {name, names} = user_name(workspace, user_id, names)
    {%{id: user_id, name: name, bot?: false}, names}
  end

  defp author(_workspace, slack_message, names) do
    {%{id: nil, name: slack_message["username"] || "Unknown", bot?: true}, names}
  end

  defp user_name(workspace, user_id, names) do
    case Map.fetch(names, user_id) do
      {:ok, name} ->
        {name, names}

      :error ->
        name =
          case Slack.user_info(workspace, user_id) do
            {:ok, user} -> get_in(user, ["profile", "real_name"]) || user["real_name"] || user["name"] || user_id
            {:error, _unreadable} -> user_id
          end

        {name, Map.put(names, user_id, name)}
    end
  end

  # Bots such as PostHog put everything in attachments or blocks and leave `text` empty.
  defp raw_text(%{"text" => text}) when is_binary(text) and text != "", do: text

  defp raw_text(slack_message) do
    attachments =
      Enum.flat_map(slack_message["attachments"] || [], fn attachment ->
        Enum.filter([attachment["pretext"], attachment["title"], attachment["text"]], &is_binary/1)
      end)

    blocks =
      Enum.flat_map(slack_message["blocks"] || [], fn
        %{"text" => %{"text" => text}} when is_binary(text) -> [text]
        _other -> []
      end)

    Enum.join(attachments ++ blocks, "\n")
  end

  defp plain(workspace, text, names) do
    {text, names} =
      ~r/<@([^|>]+)(?:\|([^>]+))?>/
      |> Regex.scan(text)
      |> Enum.reduce({text, names}, fn
        [mention, _user_id, label], {text, names} ->
          {String.replace(text, mention, "@" <> label), names}

        [mention, user_id], {text, names} ->
          {name, names} = user_name(workspace, user_id, names)
          {String.replace(text, mention, "@" <> name), names}
      end)

    text =
      text
      |> String.replace(~r/<#[^|>]+\|([^>]+)>/, "#\\1")
      |> String.replace(~r/<!subteam\^[^|>]+\|([^>]+)>/, "\\1")
      |> String.replace(~r/<!(here|channel|everyone)[^>]*>/, "@\\1")
      |> String.replace(~r/<((?:https?|mailto):[^|>]+)\|([^>]+)>/, "\\2")
      |> String.replace(~r/<((?:https?|mailto):[^>]+)>/, "\\1")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")

    {text, names}
  end

  defp posted_at(ts) do
    {seconds, fraction} = ts |> String.pad_trailing(17, "0") |> String.split(".", parts: 2) |> List.to_tuple()
    micro = fraction |> String.pad_trailing(6, "0") |> String.slice(0, 6) |> String.to_integer()
    DateTime.from_unix!(String.to_integer(seconds) * 1_000_000 + micro, :microsecond)
  end
end
