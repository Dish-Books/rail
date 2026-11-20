defmodule Rail.Support do
  @moduledoc """
  Public context for support: Intercom conversations mirrored into Rail, and the agent's
  draft reply and forward list a support person sends from the Support tab.
  """

  use Rail.PermissionsDecorator

  alias Rail.Support.Actions

  defdelegate list_intercom_workspaces(), to: Actions.ListIntercomWorkspaces
  defdelegate get_intercom_workspace(by), to: Actions.GetIntercomWorkspace

  @decorate can?(resource: :intercom_workspace, action: :create)
  defdelegate create_intercom_workspace(scope, project, attrs), to: Actions.CreateIntercomWorkspace

  @decorate can?(resource: :intercom_workspace, action: :update)
  defdelegate update_intercom_workspace(scope, workspace, attrs), to: Actions.UpdateIntercomWorkspace

  defdelegate handle_intercom_webhook(workspace, payload), to: Actions.HandleIntercomWebhook
  defdelegate backfill_intercom_workspace(workspace, starting_after), to: Actions.BackfillIntercomWorkspace
  defdelegate sync_intercom_conversation(workspace, external_id, opts \\ []), to: Actions.SyncIntercomConversation
  defdelegate list_support_conversations(opts \\ []), to: Actions.ListSupportConversations
  defdelegate count_support_conversations(opts), to: Actions.CountSupportConversations
  defdelegate get_support_conversation(scope, id), to: Actions.GetSupportConversation
  defdelegate run_support_agent(conversation), to: Actions.RunSupportAgent
  defdelegate draft_support_reply(scope, conversation), to: Actions.DraftSupportReply
  defdelegate send_support_chat(scope, conversation, attrs), to: Actions.SendSupportChat
  defdelegate update_support_draft(scope, conversation, attrs), to: Actions.UpdateSupportDraft
  defdelegate mark_support_done(scope, conversation), to: Actions.MarkSupportDone
  defdelegate send_support_reply(scope, conversation), to: Actions.SendSupportReply
end
