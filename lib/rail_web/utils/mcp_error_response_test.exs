defmodule RailWeb.Utils.McpErrorResponseTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.McpErrorResponse

  alias Anubis.Server.Response

  test "turns each reason into a tool result with isError and one sentence" do
    for {reason, text} <- [
          {{:partly_saved, [:title], [:status], {:linear_error, "down"}},
           ~s(Saved title, but not status: The ticket's tracker refused it: {:linear_error, "down"}.)},
          {:not_found, "That ticket is gone, or you can no longer open it."},
          {:split_child, "A sub-issue of a split task keeps its parent's assignee."},
          {:not_assignable, "That person can't be assigned this ticket."},
          {:unsupported, "That is edited in the ticket's own tracker."},
          {{:already_blocks, ["RAIL-1", "RAIL-2"]}, "This ticket already blocks RAIL-1, RAIL-2."},
          {"Said in full.", "Said in full."},
          {{:edited_in_tracker, :github, [:title]},
           "A GitHub ticket's title is edited in GitHub, so nothing was changed. Only its status and assignee change here, and it takes comments."}
        ] do
      assert %Response{isError: true, content: [%{"text" => ^text}]} = mcp_error_response(reason)
    end
  end
end
