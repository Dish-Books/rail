defmodule Rail.Tools.Actions.AgentFailureReasonTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  test "is the result text of the last stream-json line that has one" do
    output = """
    {"type":"system","subtype":"init"}
    {"type":"result","is_error":true,"result":"First attempt failed"}
    {"type":"assistant","message":{}}
    {"type":"result","is_error":true,"result":" Model overloaded "}
    warning: written to stderr after the stream
    """

    assert Tools.agent_failure_reason(output) == "Model overloaded"
  end

  test "an authentication failure says where to sign in again" do
    output =
      ~s({"type":"result","is_error":true,"error":"authentication_failed",) <>
        ~s("result":"Failed to authenticate: OAuth session expired and could not be refreshed"}\n)

    assert Tools.agent_failure_reason(output) ==
             "Failed to authenticate: OAuth session expired and could not be refreshed. " <>
               "Sign the backend in again under Settings → Backends."
  end

  test "is nil when no line carries result text" do
    assert Tools.agent_failure_reason("") == nil
    assert Tools.agent_failure_reason("broke\n") == nil
    assert Tools.agent_failure_reason(~s({"type":"result","result":""}\n)) == nil
    assert Tools.agent_failure_reason(~s({"event":"result","result":{"status":"error"}}\n)) == nil
    assert Tools.agent_failure_reason(~s(["result"]\n)) == nil
  end
end
