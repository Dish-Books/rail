defmodule RailWeb.Utils.BrowserDrivingTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.BrowserDriving

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  # In line for its sandbox, it has not touched the browser yet.
  test "a run waiting for resources is driving nothing" do
    assert %{verb: "idle", doing: nil, frame: nil} =
             browser_driving(%Run{status: :waiting_for_resources}, %Task{id: "tsk_waiting"})
  end
end
