defmodule Rail.Pipeline.Utils.MobileAppBrief do
  @moduledoc false

  @doc """
  How an agent that has just been told to start the app's server runs an iOS or Android change instead, judged from
  the change until Rail records a task's platforms.
  """
  def mobile_app_brief do
    "When the change reaches iOS or Android, judged from the ticket, the plan and the diff, start the project's API server that same way instead of `pnpm dev`, then build the app and install it on the iOS simulator or the Android emulator, pointed at `http://localhost:PORT`, where PORT is the port the server answers on. An Android emulator's own `localhost` is the emulator, so run `adb reverse tcp:PORT tcp:PORT` before you open the app there."
  end
end
